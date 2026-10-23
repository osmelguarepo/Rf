package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"strconv"
	"time"

	"fuelrivals/backend/internal/matchmaker"
	"fuelrivals/backend/internal/store"
	"fuelrivals/backend/internal/ticket"
)

// RunMatchmaker runs the matching loop every cfg.MatchmakerTick until ctx ends. Without MATCHMAKER=off.
func (s *Server) RunMatchmaker(ctx context.Context) {
	if s.cfg.DisableMatchmaker {
		s.log.Warn("matchmaker disabled (MATCHMAKER=off)")
		return
	}
	tick := s.cfg.MatchmakerTick
	if tick <= 0 {
		tick = time.Second
	}
	t := time.NewTicker(tick)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			s.mm.Tick(ctx)
		}
	}
}

// ipPrefix is the /24 of an IPv4 address or the /48 of an IPv6 one, as text. It is used in memory for the same-subnet
// rule of ranked matches and is never stored or logged.
func ipPrefix(ip string) string {
	parsed := net.ParseIP(ip)
	if parsed == nil {
		return ""
	}
	if v4 := parsed.To4(); v4 != nil {
		return v4.Mask(net.CIDRMask(24, 32)).String()
	}
	return parsed.Mask(net.CIDRMask(48, 128)).String()
}

// decodeOptional is decode for a body that may be empty.
func decodeOptional(w http.ResponseWriter, r *http.Request, max int64, v any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, max)
	raw, err := io.ReadAll(r.Body)
	if err != nil {
		writeError(w, http.StatusRequestEntityTooLarge, "too_large", "body too large")
		return false
	}
	if len(raw) == 0 {
		return true
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil || dec.More() {
		writeError(w, 400, "bad_request", "invalid JSON body")
		return false
	}
	return true
}

// POST /queue {"latencies": {"eu": 35, "us": 120}, "sim_hash": "..."} -> {"queue_id": "..."}
func (s *Server) handleQueueEnter(w http.ResponseWriter, r *http.Request, p store.Player) {
	if ok, wait := s.queueRL.Allow(itoa64(p.ID)); !ok {
		tooMany(w, wait)
		return
	}
	var req struct {
		Latencies map[string]int `json:"latencies"`
		SimHash   string         `json:"sim_hash"`
	}
	if !decodeOptional(w, r, 4<<10, &req) {
		return
	}
	for k := range req.Latencies {
		if !regionRe.MatchString(k) {
			writeError(w, 400, "bad_request", "latency keys are region names [a-z0-9-]")
			return
		}
	}
	if len(req.SimHash) > 64 {
		writeError(w, 400, "bad_request", "sim_hash too long")
		return
	}
	prof, err := s.store.QueueProfileOf(r.Context(), p)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	id, err := s.mm.Enter(r.Context(), matchmaker.EnterInput{
		PlayerID: p.ID, Guest: p.Guest, Points: prof.Points, Rating: prof.Rating, Latencies: req.Latencies,
		IPPrefix: ipPrefix(s.clientIP(r)), SimHash: req.SimHash,
	})
	var ban *matchmaker.BanError
	switch {
	case errors.As(err, &ban):
		secs := int(ban.Until.Sub(s.now()).Seconds()) + 1
		w.Header().Set("Retry-After", itoa(secs))
		writeJSON(w, 403, map[string]any{"error": "queue_banned", "message": "the queue is closed to you for leaving matches",
			"retry_after_s": secs, "banned_until_unix": ban.Until.Unix()})
	case errors.Is(err, matchmaker.ErrBusy):
		writeError(w, 409, "busy", "you are in a match or a ready-check")
	case err != nil:
		s.fail(w, r, err)
	default:
		writeJSON(w, 200, map[string]string{"queue_id": id})
	}
}

// GET /queue/status
func (s *Server) handleQueueStatus(w http.ResponseWriter, r *http.Request, p store.Player) {
	if ok, wait := s.statusRL.Allow(itoa64(p.ID)); !ok {
		tooMany(w, wait)
		return
	}
	writeJSON(w, 200, s.mm.Status(p.ID))
}

// POST /queue/ready {"match_id": "123"}
func (s *Server) handleQueueReady(w http.ResponseWriter, r *http.Request, p store.Player) {
	if ok, wait := s.queueRL.Allow(itoa64(p.ID)); !ok {
		tooMany(w, wait)
		return
	}
	var req struct {
		MatchID string `json:"match_id"`
	}
	if !decode(w, r, 1<<10, &req) {
		return
	}
	id, err := strconv.ParseInt(req.MatchID, 10, 64)
	if err != nil || id <= 0 {
		writeError(w, 400, "bad_request", "invalid match_id")
		return
	}
	if err := s.mm.Confirm(p.ID, id); err != nil {
		writeError(w, 404, "no_match", "there is no found match with that id for you (it may have expired)")
		return
	}
	writeJSON(w, 200, s.mm.Status(p.ID))
}

// DELETE /queue: leaves the queue. After a match was found it declines it, which counts as a strike.
func (s *Server) handleQueueLeave(w http.ResponseWriter, r *http.Request, p store.Player) {
	if ok, wait := s.queueRL.Allow(itoa64(p.ID)); !ok {
		tooMany(w, wait)
		return
	}
	prev := s.mm.Leave(r.Context(), p.ID)
	writeJSON(w, 200, map[string]string{"state": matchmaker.StateIdle, "was": prev})
}

// GET /match/{id}/join -> {"ws_url", "ticket", ...}. The ticket is the base64url string of TICKET.md; it is valid for
// 60 s from the first request. Asking again inside that time returns the same ticket; later, 409.
func (s *Server) handleMatchJoin(w http.ResponseWriter, r *http.Request, p store.Player) {
	id, ok := matchID(r)
	if !ok {
		writeError(w, 400, "bad_request", "invalid match id")
		return
	}
	seat, err := s.store.SeatOf(r.Context(), id, p.ID)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	switch {
	case seat.Status == "void" || seat.Status == "annulled":
		writeError(w, 410, "gone", "the match is void")
		return
	case seat.Status == "settled":
		writeError(w, 409, "finished", "the match is over")
		return
	case seat.LeftAt != nil:
		writeError(w, 409, "left", "you left this match")
		return
	}
	sv, err := s.store.ServerByID(r.Context(), seat.ServerID)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	issued, err := s.store.MarkJoinIssued(r.Context(), id, p.ID)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	expires := issued.Add(ticket.TTL)
	if !s.now().Before(expires) {
		writeError(w, 409, "ticket_expired", "the ticket of this seat was issued and has expired; leave the match")
		return
	}
	tk, err := ticket.Sign(s.store.KeyOf(sv), ticket.Ticket{
		ServerID: sv.IDString(), MatchID: itoa64(id), Seat: seat.Seat, PlayerID: itoa64(p.ID),
		SteamID: seat.SteamID, Name: seat.Name, Seed: seat.Seed, Expires: expires.Unix(),
	})
	if err != nil {
		s.log.Error("ticket", "err", err.Error())
		writeError(w, 500, "internal", "could not sign the ticket")
		return
	}
	s.mm.ForgetStarted(p.ID)
	writeJSON(w, 200, map[string]any{
		"ws_url": sv.URL, "ticket": tk, "match_id": itoa64(id), "seat": seat.Seat, "expires_unix": expires.Unix(),
	})
}

// POST /match/{id}/leave: the player leaves a match. If they had a ticket this is an abandon (a strike for the queue
// penalty); the game server sees the closed socket and reports the abandon in its result. When every human left an
// unsettled match it becomes void.
func (s *Server) handleMatchLeave(w http.ResponseWriter, r *http.Request, p store.Player) {
	id, ok := matchID(r)
	if !ok {
		writeError(w, 400, "bad_request", "invalid match id")
		return
	}
	res, err := s.store.MarkLeft(r.Context(), id, p.ID)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	s.mm.ForgetStarted(p.ID)
	if !res.Already && (res.Status == "assigned" || res.Voided) {
		s.mm.Strike(r.Context(), p.ID, matchmaker.StrikeLeftMatch)
	}
	if res.Voided {
		s.log.Info("match voided: every human left", "match_id", id)
	}
	writeJSON(w, 200, map[string]any{"left": true, "already": res.Already, "match_status": res.Status})
}

// GET /metrics (Prometheus text) with METRICS_TOKEN as bearer token. Without the token configured it answers 404.
func (s *Server) handleMetrics(w http.ResponseWriter, r *http.Request) {
	if s.cfg.MetricsToken == "" {
		writeError(w, 404, "not_found", "metrics are not enabled")
		return
	}
	if !tokenEquals(bearer(r), s.cfg.MetricsToken) {
		writeError(w, 401, "unauthorized", "metrics token required")
		return
	}
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	s.metrics.WritePrometheus(w)
}
