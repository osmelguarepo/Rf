package api

import (
	"net/http"
	"strconv"
	"time"

	"fuelrivals/backend/internal/store"
)

// GET /admin/matches?status=assigned&limit=50
func (s *Server) handleAdminMatches(w http.ResponseWriter, r *http.Request) {
	status := r.URL.Query().Get("status")
	switch status {
	case "", "assigned", "settled", "void", "annulled":
	default:
		writeError(w, 400, "bad_request", "status must be assigned, settled, void or annulled")
		return
	}
	limit := 50
	if v := r.URL.Query().Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > 500 {
			writeError(w, 400, "bad_request", "limit is 1 to 500")
			return
		}
		limit = n
	}
	list, err := s.store.ListMatches(r.Context(), status, limit)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	out := make([]map[string]any, 0, len(list))
	for _, m := range list {
		humans, err := s.store.MatchHumans(r.Context(), m.MatchID)
		if err != nil {
			s.fail(w, r, err)
			return
		}
		ids := make([]string, len(humans))
		for i, h := range humans {
			ids[i] = itoa64(h)
		}
		out = append(out, map[string]any{
			"match_id": itoa64(m.MatchID), "server_id": itoa64(m.ServerID), "status": m.Status, "ranked": m.Ranked,
			"rank_reason": m.Reason, "humans": m.Humans, "bots": m.Bots, "released": m.Released, "created_at": m.CreatedAt,
			"player_ids": ids,
		})
	}
	writeJSON(w, 200, map[string]any{"matches": out})
}

// GET /admin/servers
func (s *Server) handleAdminServers(w http.ResponseWriter, r *http.Request) {
	list, err := s.store.ListServers(r.Context())
	if err != nil {
		s.fail(w, r, err)
		return
	}
	out := make([]map[string]any, 0, len(list))
	for _, sv := range list {
		out = append(out, map[string]any{
			"server_id": sv.IDString(), "name": sv.Name, "region": sv.Region, "url": sv.URL, "capacity": sv.Capacity,
			"open_matches": sv.OpenMatches, "reported_active_matches": sv.ActiveMatches, "alive": sv.LeaseAlive,
			"draining": sv.Draining, "drain_requested": sv.DrainRequested, "sim_hash": sv.SimHash, "game_version": sv.GameVersion,
			"last_heartbeat": sv.LastHeartbeat,
		})
	}
	writeJSON(w, 200, map[string]any{"servers": out})
}

// POST /admin/servers/{id}/drain {"drain": true}: stop assigning matches to the server; its next heartbeat reply asks
// it to drain. {"drain": false} lifts it.
func (s *Server) handleAdminDrain(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		writeError(w, 400, "bad_request", "invalid server id")
		return
	}
	req := struct {
		Drain *bool `json:"drain"`
	}{}
	if !decodeOptional(w, r, 1<<10, &req) {
		return
	}
	drain := req.Drain == nil || *req.Drain
	if err := s.store.SetDrain(r.Context(), id, drain); err != nil {
		s.fail(w, r, err)
		return
	}
	s.log.Info("server drain", "server_id", id, "drain", drain)
	writeJSON(w, 200, map[string]any{"server_id": itoa64(id), "drain": drain})
}

// POST /admin/players/{id}/unban
func (s *Server) handleAdminUnban(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		writeError(w, 400, "bad_request", "invalid player id")
		return
	}
	if err := s.store.UnbanPlayer(r.Context(), id, "admin"); err != nil {
		s.fail(w, r, err)
		return
	}
	s.mm.ClearPenalty(id)
	writeJSON(w, 200, map[string]bool{"banned": false})
}

// GET /admin/queue: who waits, and the matches waiting for confirmations.
func (s *Server) handleAdminQueue(w http.ResponseWriter, r *http.Request) {
	q, pend := s.mm.Snapshot()
	p := s.mm.Params()
	writeJSON(w, 200, map[string]any{
		"queue": q, "pending": pend,
		"params": map[string]any{
			"queue_max_wait_s": p.MaxWait.Seconds(), "queue_solo_wait_s": p.SoloWait.Seconds(),
			"ready_seconds": p.ReadyWindow.Seconds(), "max_ping_ms": p.MaxPingMS,
		},
		"now": time.Now().UTC(),
	})
}

// heartbeatReply is what a game server learns from every heartbeat: the lease, whether an operator asked it to drain,
// and how the API counts its capacity.
func (s *Server) heartbeatReply(r *http.Request, sv store.Server) map[string]any {
	reply := map[string]any{"ok": true, "lease_seconds": int(s.cfg.LeaseTTL.Seconds())}
	drain, err := s.store.DrainRequested(r.Context(), sv.ID)
	if err != nil {
		s.log.Error("heartbeat reply", "err", err.Error())
	}
	reply["drain"] = drain
	list, err := s.store.ListServers(r.Context())
	if err == nil {
		for _, x := range list {
			if x.ID == sv.ID {
				reply["capacity"] = x.Capacity
				reply["assigned_matches"] = x.OpenMatches
				reply["free"] = max(x.Capacity-x.OpenMatches, 0)
			}
		}
	}
	return reply
}
