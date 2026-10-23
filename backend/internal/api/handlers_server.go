package api

import (
	"errors"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"

	"fuelrivals/backend/internal/store"
)

var (
	serverNameRe = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,31}$`)
	regionRe     = regexp.MustCompile(`^[a-z0-9-]{1,16}$`)
	formatRe     = regexp.MustCompile(`^[a-z0-9._-]{1,32}$`)
)

// POST /servers/register {"name","region","url","capacity"}, with the registration token. Registering a name that
// exists rotates its key. The key is shown once.
func (s *Server) handleServerRegister(w http.ResponseWriter, r *http.Request) {
	if !tokenEquals(bearer(r), s.cfg.ServerRegisterToken) {
		writeError(w, 401, "unauthorized", "registration token required")
		return
	}
	var req struct {
		Name     string `json:"name"`
		Region   string `json:"region"`
		URL      string `json:"url"`
		Capacity int    `json:"capacity"`
	}
	if !decode(w, r, 4<<10, &req) {
		return
	}
	okURL := (strings.HasPrefix(req.URL, "wss://") || strings.HasPrefix(req.URL, "ws://localhost") ||
		strings.HasPrefix(req.URL, "ws://127.0.0.1")) && len(req.URL) <= 200
	if !serverNameRe.MatchString(req.Name) || !regionRe.MatchString(req.Region) || !okURL || req.Capacity < 1 || req.Capacity > 10000 {
		writeError(w, 400, "bad_request", "name [a-z0-9-], region [a-z0-9-], a wss:// url and a capacity of 1 to 10000 are required")
		return
	}
	sv, key, err := s.store.RegisterServer(r.Context(), req.Name, req.Region, req.URL, req.Capacity)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	s.log.Info("game server registered", "server_id", sv.ID, "name", sv.Name, "key_version", sv.KeyVersion)
	writeJSON(w, 201, map[string]any{
		"server_id": sv.IDString(), "key": key, "key_version": sv.KeyVersion,
		"note": "Keep the key secret: it signs tickets and authenticates this server. Registering the same name again rotates it.",
	})
}

// POST /servers/heartbeat: renews the lease and reports capacity, drain state and metrics.
func (s *Server) handleHeartbeat(w http.ResponseWriter, r *http.Request, sv store.Server) {
	var hb store.Heartbeat
	if !decode(w, r, 8<<10, &hb) {
		return
	}
	if err := hb.Validate(); err != nil {
		s.fail(w, r, err)
		return
	}
	if err := s.store.RecordHeartbeat(r.Context(), sv.ID, hb, s.cfg.LeaseTTL); err != nil {
		s.fail(w, r, err)
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true, "lease_seconds": int(s.cfg.LeaseTTL.Seconds())})
}

type resultRequest struct {
	Players []struct {
		PlayerID  string `json:"player_id"`
		Place     int    `json:"place"`
		Abandoned bool   `json:"abandoned"`
	} `json:"players"`
	// Informational; stored with the replay by the server, not used for points.
	FinalChecksum string `json:"final_checksum"`
}

func matchID(r *http.Request) (int64, bool) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	return id, err == nil && id > 0
}

// POST /matches/{id}/result: only placements and abandons of the humans the API assigned to this server.
func (s *Server) handleResult(w http.ResponseWriter, r *http.Request, sv store.Server) {
	id, ok := matchID(r)
	if !ok {
		writeError(w, 400, "bad_request", "invalid match id")
		return
	}
	var req resultRequest
	if !decode(w, r, 16<<10, &req) {
		return
	}
	entries := make([]store.ResultEntry, 0, len(req.Players))
	for _, p := range req.Players {
		pid, err := strconv.ParseInt(p.PlayerID, 10, 64)
		if err != nil || pid <= 0 {
			writeError(w, 400, "bad_request", "invalid player_id")
			return
		}
		entries = append(entries, store.ResultEntry{PlayerID: pid, Place: p.Place, Abandoned: p.Abandoned})
	}
	res, err := s.store.SettleMatch(r.Context(), id, sv.ID, entries)
	if err != nil {
		if errors.Is(err, store.ErrConflict) {
			s.log.Error("conflicting match result", "match_id", id, "server_id", sv.ID)
		}
		s.fail(w, r, err)
		return
	}
	players := make([]map[string]any, 0, len(res.Players))
	for _, p := range res.Players {
		players = append(players, map[string]any{
			"player_id": itoa64(p.PlayerID), "seat": p.Seat, "scored": p.Scored, "final_place": p.FinalPlace,
			"abandoned": p.Abandoned, "points_before": p.Before, "points_after": p.After, "applied_delta": p.Applied,
			"division": p.Division, "division_name": p.DivisionName,
		})
	}
	writeJSON(w, 200, map[string]any{
		"match_id": itoa64(res.MatchID), "ranked": res.Ranked, "rank_reason": res.Reason, "already_settled": res.Already, "players": players,
	})
}

// POST /matches/{id}/replay: the compressed replay as the request body.
func (s *Server) handleReplayUpload(w http.ResponseWriter, r *http.Request, sv store.Server) {
	id, ok := matchID(r)
	if !ok {
		writeError(w, 400, "bad_request", "invalid match id")
		return
	}
	format := r.Header.Get("X-Replay-Format")
	if format == "" {
		format = "gzip"
	}
	if !formatRe.MatchString(format) {
		writeError(w, 400, "bad_request", "invalid X-Replay-Format")
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, s.cfg.ReplayMaxBytes))
	if err != nil {
		writeError(w, http.StatusRequestEntityTooLarge, "too_large", "replay larger than "+itoa64(s.cfg.ReplayMaxBytes)+" bytes")
		return
	}
	if len(body) == 0 {
		writeError(w, 400, "bad_request", "empty replay")
		return
	}
	created, err := s.store.StoreReplay(r.Context(), id, sv.ID, format, body)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	status := 200
	if created {
		status = 201
	}
	writeJSON(w, status, map[string]any{"ok": true, "stored": created})
}

