package api

import (
	"net/http"
	"strconv"
	"strings"
	"unicode/utf8"

	"fuelrivals/backend/internal/store"
)

func (s *Server) handleMe(w http.ResponseWriter, r *http.Request, p store.Player) {
	prof, err := s.store.ProfileOf(r.Context(), p)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	writeJSON(w, 200, prof)
}

// POST /account/delete {"confirm": "DELETE"}
func (s *Server) handleDeleteAccount(w http.ResponseWriter, r *http.Request, p store.Player) {
	var req struct {
		Confirm string `json:"confirm"`
	}
	if !decode(w, r, 1<<10, &req) {
		return
	}
	if req.Confirm != "DELETE" {
		writeError(w, 400, "bad_request", `send {"confirm":"DELETE"} to delete the account`)
		return
	}
	if err := s.store.DeleteAccount(r.Context(), p.ID); err != nil {
		s.fail(w, r, err)
		return
	}
	writeJSON(w, 200, map[string]bool{"deleted": true})
}

func (s *Server) handleExport(w http.ResponseWriter, r *http.Request, p store.Player) {
	ex, err := s.store.ExportAccount(r.Context(), p.ID)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	w.Header().Set("Content-Disposition", `attachment; filename="fuel-rivals-data.json"`)
	writeJSON(w, 200, ex)
}

func (s *Server) handleLeaderboard(w http.ResponseWriter, r *http.Request) {
	limit := 10
	if v := r.URL.Query().Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 {
			writeError(w, 400, "bad_request", "limit must be a positive number")
			return
		}
		limit = n
	}
	entries, err := s.store.Leaderboard(r.Context(), limit)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	w.Header().Set("Cache-Control", "public, max-age=5")
	writeJSON(w, 200, map[string]any{"entries": entries})
}

// POST /reports {"target_player_id": "12", "match_id": "3", "reason": "..."}
func (s *Server) handleReport(w http.ResponseWriter, r *http.Request, p store.Player) {
	var req struct {
		Target string `json:"target_player_id"`
		Match  string `json:"match_id"`
		Reason string `json:"reason"`
	}
	if !decode(w, r, 4<<10, &req) {
		return
	}
	target, err := strconv.ParseInt(req.Target, 10, 64)
	reason := strings.TrimSpace(req.Reason)
	if err != nil || target <= 0 || target == p.ID || reason == "" || utf8.RuneCountInString(reason) > 200 {
		writeError(w, 400, "bad_request", "target_player_id (not yourself) and a reason of 1 to 200 characters are required")
		return
	}
	var match *int64
	if req.Match != "" {
		m, err := strconv.ParseInt(req.Match, 10, 64)
		if err != nil || m <= 0 {
			writeError(w, 400, "bad_request", "invalid match_id")
			return
		}
		match = &m
	}
	if err := s.store.AddReport(r.Context(), p.ID, target, match, reason); err != nil {
		s.fail(w, r, err)
		return
	}
	writeJSON(w, 201, map[string]bool{"ok": true})
}
