package api

import (
	"net/http"
	"strconv"

	"fuelrivals/backend/internal/store"
	"fuelrivals/backend/internal/ticket"
)

// POST /admin/matches: records a match on a server and returns each human's ticket. This is what the matchmaker
// (milestone M4) calls internally; until then it is the admin entry point. The ticket carries the seat, seed and
// players, and is signed with the target server's key.
func (s *Server) handleAdminAssign(w http.ResponseWriter, r *http.Request) {
	var req struct {
		ServerID    string `json:"server_id"`
		GameVersion string `json:"game_version"`
		SimHash     string `json:"sim_hash"`
		Seats       []struct {
			PlayerID string `json:"player_id"`
			Seat     int    `json:"seat"`
			IPPrefix string `json:"ip_prefix"` // the /24 from the matchmaker's memory; not stored
		} `json:"seats"`
	}
	if !decode(w, r, 8<<10, &req) {
		return
	}
	sid, err := strconv.ParseInt(req.ServerID, 10, 64)
	if err != nil || sid <= 0 {
		writeError(w, 400, "bad_request", "invalid server_id")
		return
	}
	seats := make([]store.SeatRequest, 0, len(req.Seats))
	for _, st := range req.Seats {
		pid, err := strconv.ParseInt(st.PlayerID, 10, 64)
		if err != nil || pid <= 0 {
			writeError(w, 400, "bad_request", "invalid player_id")
			return
		}
		seats = append(seats, store.SeatRequest{PlayerID: pid, Seat: st.Seat, IPPrefix: st.IPPrefix})
	}
	sv, err := s.store.ServerByID(r.Context(), sid)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	a, err := s.store.AssignMatch(r.Context(), store.AssignRequest{ServerID: sid, Seats: seats, GameVersion: req.GameVersion, SimHash: req.SimHash})
	if err != nil {
		s.fail(w, r, err)
		return
	}
	key := s.store.KeyOf(sv)
	now := s.now()
	type issued struct {
		Seat     int    `json:"seat"`
		PlayerID string `json:"player_id"`
		Name     string `json:"name"`
		Ticket   string `json:"ticket"`
	}
	tickets := make([]issued, 0, len(a.Seats))
	for _, seat := range a.Seats {
		name := seat.Name
		if seat.Guest {
			name = ""
		}
		t, err := ticket.Issue(key, ticket.Ticket{
			ServerID: sv.IDString(), MatchID: itoa64(a.MatchID), Seat: seat.Seat, PlayerID: itoa64(seat.PlayerID),
			SteamID: seat.SteamID, Name: name, Seed: a.Seed,
		}, now)
		if err != nil {
			s.log.Error("ticket", "err", err.Error())
			// The match is recorded but unusable: void it so the players are not stuck.
			_, _ = s.store.AnnulMatch(r.Context(), a.MatchID, "ticket signing failed", "system")
			writeError(w, 500, "internal", "could not sign tickets")
			return
		}
		tickets = append(tickets, issued{Seat: seat.Seat, PlayerID: itoa64(seat.PlayerID), Name: name, Ticket: t})
	}
	writeJSON(w, 201, map[string]any{
		"match_id": itoa64(a.MatchID), "seed": itoa64(a.Seed), "ranked": a.Ranked, "rank_reason": a.Reason,
		"bots": a.Bots, "server_url": sv.URL, "tickets": tickets,
	})
}

func (s *Server) handleAdminMatch(w http.ResponseWriter, r *http.Request) {
	id, ok := matchID(r)
	if !ok {
		writeError(w, 400, "bad_request", "invalid match id")
		return
	}
	m, err := s.store.GetMatch(r.Context(), id)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	writeJSON(w, 200, map[string]any{
		"match_id": itoa64(m.MatchID), "server_id": itoa64(m.ServerID), "status": m.Status, "ranked": m.Ranked,
		"rank_reason": m.Reason, "released": m.Released, "players": m.Players,
	})
}

// POST /admin/matches/{id}/annul {"reason": "..."}
func (s *Server) handleAdminAnnul(w http.ResponseWriter, r *http.Request) {
	id, ok := matchID(r)
	if !ok {
		writeError(w, 400, "bad_request", "invalid match id")
		return
	}
	var req struct {
		Reason string `json:"reason"`
	}
	if !decode(w, r, 2<<10, &req) {
		return
	}
	if req.Reason == "" || len(req.Reason) > 200 {
		writeError(w, 400, "bad_request", "a reason of 1 to 200 characters is required")
		return
	}
	res, err := s.store.AnnulMatch(r.Context(), id, req.Reason, "admin")
	if err != nil {
		s.fail(w, r, err)
		return
	}
	writeJSON(w, 200, map[string]any{"match_id": itoa64(id), "status": res.Status, "already": res.Already, "reverted": res.Reverted})
}

func (s *Server) handleAdminReplay(w http.ResponseWriter, r *http.Request) {
	id, ok := matchID(r)
	if !ok {
		writeError(w, 400, "bad_request", "invalid match id")
		return
	}
	format, data, err := s.store.GetReplay(r.Context(), id)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("X-Replay-Format", format)
	_, _ = w.Write(data)
}

// POST /admin/players/{id}/ban {"reason": "..."}
func (s *Server) handleAdminBan(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		writeError(w, 400, "bad_request", "invalid player id")
		return
	}
	var req struct {
		Reason string `json:"reason"`
	}
	if !decode(w, r, 2<<10, &req) {
		return
	}
	if err := s.store.BanPlayer(r.Context(), id, req.Reason, "admin"); err != nil {
		s.fail(w, r, err)
		return
	}
	writeJSON(w, 200, map[string]bool{"banned": true})
}
