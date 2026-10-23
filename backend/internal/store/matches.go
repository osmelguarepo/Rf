package store

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"fuelrivals/backend/internal/ranking"
)

// SeatRequest is a human the matchmaker puts in a match.
type SeatRequest struct {
	PlayerID int64
	Seat     int
	// IPPrefix is the /24 of the player's address, taken from memory by the matchmaker; it is used for the same-subnet
	// rule and never stored.
	IPPrefix string
}

// AssignRequest asks the API to record that a server will host these humans (the rest of the 6 cars are bots).
type AssignRequest struct {
	ServerID    int64
	Seats       []SeatRequest
	GameVersion string
	SimHash     string
}

// AssignedSeat is one human of an assigned match, with what its ticket needs.
type AssignedSeat struct {
	PlayerID int64
	Seat     int
	SteamID  string // "" for guests
	Name     string
	Guest    bool
}

// Assignment is the recorded match.
type Assignment struct {
	MatchID int64
	Seed    int64
	Ranked  bool
	Reason  string
	Bots    int
	Seats   []AssignedSeat
}

func randomSeed() int64 {
	var b [8]byte
	_, _ = rand.Read(b[:])
	return int64(binary.BigEndian.Uint64(b[:]) >> 1)
}

// AssignMatch records a match on a server: the humans (the only ones whose results the server may report), the seed
// and whether it ranks. A player can be in one match at a time (ErrBusy).
func (s *Store) AssignMatch(ctx context.Context, req AssignRequest) (Assignment, error) {
	if len(req.Seats) < 1 || len(req.Seats) > 6 {
		return Assignment{}, fmt.Errorf("%w: 1 to 6 humans", ErrBadRequest)
	}
	seatUsed := map[int]bool{}
	ids := make([]int64, 0, len(req.Seats))
	seen := map[int64]bool{}
	for _, st := range req.Seats {
		if st.Seat < 0 || st.Seat > 5 || seatUsed[st.Seat] || seen[st.PlayerID] {
			return Assignment{}, fmt.Errorf("%w: seats and players must be distinct, seats 0 to 5", ErrBadRequest)
		}
		seatUsed[st.Seat] = true
		seen[st.PlayerID] = true
		ids = append(ids, st.PlayerID)
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })

	var out Assignment
	err := s.withTx(ctx, func(tx pgx.Tx) error {
		now := s.Now()
		// The server must be alive, open and with room.
		var capacity, open int
		var draining bool
		var lease *time.Time
		err := tx.QueryRow(ctx, `SELECT capacity, draining, lease_expires_at,
			(SELECT count(*) FROM matches m WHERE m.server_id = sv.server_id AND m.status = 'assigned' AND NOT m.released)
			FROM servers sv WHERE server_id = $1 FOR SHARE`, req.ServerID).Scan(&capacity, &draining, &lease, &open)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if draining || lease == nil || lease.Before(now) || open >= capacity {
			return ErrDraining
		}

		// Lock the players in id order: two matchmakers cannot assign the same player at once.
		rows, err := tx.Query(ctx, `SELECT player_id, COALESCE(steam_id, ''), name, is_guest FROM players
			WHERE player_id = ANY($1) AND deleted_at IS NULL AND NOT banned ORDER BY player_id FOR UPDATE`, ids)
		if err != nil {
			return err
		}
		info := map[int64]AssignedSeat{}
		for rows.Next() {
			var a AssignedSeat
			if err := rows.Scan(&a.PlayerID, &a.SteamID, &a.Name, &a.Guest); err != nil {
				rows.Close()
				return err
			}
			info[a.PlayerID] = a
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}
		if len(info) != len(ids) {
			return fmt.Errorf("%w: unknown, banned or deleted player", ErrNotFound)
		}
		var busy bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM match_players mp JOIN matches m USING (match_id)
			WHERE mp.player_id = ANY($1) AND m.status = 'assigned' AND NOT m.released)`, ids).Scan(&busy); err != nil {
			return err
		}
		if busy {
			return ErrBusy
		}

		// Is it ranked? Guests never score and are left out of the rule; the others must pass it together.
		var cands []ranking.Candidate
		points := map[int64]int{}
		for _, st := range req.Seats {
			if info[st.PlayerID].Guest {
				continue
			}
			var p int
			if err := tx.QueryRow(ctx, `SELECT points FROM ratings WHERE player_id = $1`, st.PlayerID).Scan(&p); err != nil {
				return err
			}
			points[st.PlayerID] = p
			cands = append(cands, ranking.Candidate{PlayerID: st.PlayerID, Points: p, IPPrefix: st.IPPrefix})
		}
		today := now.UTC().Truncate(24 * time.Hour)
		recent := map[[2]int64]int{}
		for i := range cands {
			for j := i + 1; j < len(cands); j++ {
				a, b := orderedPair(cands[i].PlayerID, cands[j].PlayerID)
				var n int
				err := tx.QueryRow(ctx, `SELECT COALESCE(sum(n), 0) FROM pairings WHERE day = $1 AND a = $2 AND b = $3`, today, a, b).Scan(&n)
				if err != nil {
					return err
				}
				recent[[2]int64{a, b}] = n
			}
		}
		verdict := ranking.Evaluate(cands, func(x, y int64) int {
			a, b := orderedPair(x, y)
			return recent[[2]int64{a, b}]
		})
		for k := range recent {
			if _, err := tx.Exec(ctx, `INSERT INTO pairings (day, a, b) VALUES ($1, $2, $3)
				ON CONFLICT (day, a, b) DO UPDATE SET n = pairings.n + 1`, today, k[0], k[1]); err != nil {
				return err
			}
		}

		out = Assignment{Seed: randomSeed(), Ranked: verdict.Ranked, Reason: verdict.Reason, Bots: 6 - len(req.Seats)}
		err = tx.QueryRow(ctx, `INSERT INTO matches (server_id, seed, humans, bots, ranked, rank_reason, game_version, sim_hash, created_at)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) RETURNING match_id`,
			req.ServerID, out.Seed, len(req.Seats), out.Bots, out.Ranked, out.Reason, req.GameVersion, req.SimHash, now).Scan(&out.MatchID)
		if err != nil {
			return err
		}
		for _, st := range req.Seats {
			a := info[st.PlayerID]
			a.Seat = st.Seat
			scores := out.Ranked && !a.Guest
			if _, err := tx.Exec(ctx, `INSERT INTO match_players (match_id, seat, player_id, ranked) VALUES ($1, $2, $3, $4)`,
				out.MatchID, st.Seat, st.PlayerID, scores); err != nil {
				return err
			}
			out.Seats = append(out.Seats, a)
		}
		sort.Slice(out.Seats, func(i, j int) bool { return out.Seats[i].Seat < out.Seats[j].Seat })
		return nil
	})
	return out, err
}

func orderedPair(x, y int64) (int64, int64) {
	if x < y {
		return x, y
	}
	return y, x
}

// ResultEntry is what a game server reports for one human: its place among the cars and whether it left.
type ResultEntry struct {
	PlayerID  int64 `json:"-"`
	Place     int
	Abandoned bool
}

// SettledPlayer is the outcome for one human of a settled match.
type SettledPlayer struct {
	PlayerID     int64  `json:"-"`
	Seat         int    `json:"seat"`
	Scored       bool   `json:"scored"`
	FinalPlace   int    `json:"final_place"`
	Abandoned    bool   `json:"abandoned"`
	Before       int    `json:"points_before"`
	After        int    `json:"points_after"`
	Applied      int    `json:"applied_delta"`
	Division     int    `json:"division"`
	DivisionName string `json:"division_name"`
}

// Settlement is the outcome of a settled match.
type Settlement struct {
	MatchID int64
	Ranked  bool
	Reason  string
	Already bool // the same result had been settled before
	Players []SettledPlayer
}

// resultHash identifies a report independently of the order of its entries.
func resultHash(entries []ResultEntry) []byte {
	sorted := append([]ResultEntry(nil), entries...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].PlayerID < sorted[j].PlayerID })
	var b strings.Builder
	for _, e := range sorted {
		fmt.Fprintf(&b, "%d:%d:%t\n", e.PlayerID, e.Place, e.Abandoned)
	}
	h := sha256.Sum256([]byte(b.String()))
	return h[:]
}

// SettleMatch applies a game server's result. Rules (SPEC_ONLINE 16.2):
//   - only the server the match was assigned to, and only for the humans assigned (placements and abandons);
//   - the API computes the points; the change actually applied (after the floor of 0) is stored;
//   - the first result wins: the same report again returns the stored outcome, a different one is ErrConflict.
func (s *Store) SettleMatch(ctx context.Context, matchID, serverID int64, entries []ResultEntry) (Settlement, error) {
	if err := validateEntries(entries); err != nil {
		return Settlement{}, err
	}
	hash := resultHash(entries)
	var out Settlement
	err := s.withTx(ctx, func(tx pgx.Tx) error {
		out = Settlement{MatchID: matchID}
		var owner int64
		var status string
		var stored []byte
		err := tx.QueryRow(ctx, `SELECT server_id, status, ranked, rank_reason, result_hash FROM matches WHERE match_id = $1 FOR UPDATE`,
			matchID).Scan(&owner, &status, &out.Ranked, &out.Reason, &stored)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if owner != serverID {
			return ErrForbidden
		}
		switch status {
		case "void", "annulled":
			return ErrGone
		case "settled":
			if string(stored) != string(hash) {
				return ErrConflict
			}
			out.Already = true
			out.Players, err = loadSettled(ctx, tx, matchID)
			return err
		}

		// The report must be about exactly the humans assigned.
		assigned, err := loadSeats(ctx, tx, matchID)
		if err != nil {
			return err
		}
		if len(assigned) != len(entries) {
			return fmt.Errorf("%w: the report lists %d players, the match has %d", ErrBadRequest, len(entries), len(assigned))
		}
		reported := map[int64]ResultEntry{}
		for _, e := range entries {
			reported[e.PlayerID] = e
		}
		for _, a := range assigned {
			if _, ok := reported[a.playerID]; !ok {
				return fmt.Errorf("%w: player %d of the match is missing from the report", ErrBadRequest, a.playerID)
			}
		}

		// Points: only the scoring humans, ranked among themselves.
		var scoring []ranking.Entry
		for _, a := range assigned {
			if a.scored {
				e := reported[a.playerID]
				scoring = append(scoring, ranking.Entry{PlayerID: a.playerID, Place: e.Place, Abandoned: e.Abandoned})
			}
		}
		sort.Slice(scoring, func(i, j int) bool { return scoring[i].PlayerID < scoring[j].PlayerID })
		outcomes := map[int64]ranking.Outcome{}
		if out.Ranked && len(scoring) >= 2 {
			for _, o := range ranking.Settle(scoring) {
				outcomes[o.PlayerID] = o
			}
			// Hidden ratings before the match, locked in player order.
			skills := make([]ranking.Skill, len(scoring))
			places := make([]int, len(scoring))
			pts := make([]int, len(scoring))
			for i, e := range scoring {
				err := tx.QueryRow(ctx, `SELECT points, rating, dev, vol FROM ratings WHERE player_id = $1 FOR UPDATE`, e.PlayerID).
					Scan(&pts[i], &skills[i].Rating, &skills[i].Dev, &skills[i].Vol)
				if err != nil {
					return err
				}
				places[i] = outcomes[e.PlayerID].FinalPlace
			}
			newSkills := ranking.RatePlacements(places, skills)
			for i, e := range scoring {
				o := outcomes[e.PlayerID]
				after := ranking.Apply(pts[i], o.Delta)
				if _, err := tx.Exec(ctx, `UPDATE ratings SET points = $2, rating = $3, dev = $4, vol = $5,
					ranked_matches = ranked_matches + 1, last_match_id = $6, updated_at = $7 WHERE player_id = $1`,
					e.PlayerID, after, newSkills[i].Rating, newSkills[i].Dev, newSkills[i].Vol, matchID, s.Now()); err != nil {
					return err
				}
				if _, err := tx.Exec(ctx, `UPDATE match_players SET points_before = $3, points_after = $4, applied_delta = $5,
					rating_before = $6, dev_before = $7, vol_before = $8 WHERE match_id = $1 AND player_id = $2`,
					matchID, e.PlayerID, pts[i], after, after-pts[i], skills[i].Rating, skills[i].Dev, skills[i].Vol); err != nil {
					return err
				}
			}
		}
		for _, a := range assigned {
			e := reported[a.playerID]
			final := e.Place
			if o, ok := outcomes[a.playerID]; ok {
				final = o.FinalPlace
			}
			if _, err := tx.Exec(ctx, `UPDATE match_players SET abandoned = $3, reported_place = $4, final_place = $5
				WHERE match_id = $1 AND player_id = $2`, matchID, a.playerID, e.Abandoned, e.Place, final); err != nil {
				return err
			}
		}
		resultDoc := make([]map[string]any, 0, len(entries))
		for _, e := range entries {
			resultDoc = append(resultDoc, map[string]any{"player_id": e.PlayerID, "place": e.Place, "abandoned": e.Abandoned})
		}
		if _, err := tx.Exec(ctx, `UPDATE matches SET status = 'settled', settled_at = $2, result_hash = $3, result = $4 WHERE match_id = $1`,
			matchID, s.Now(), hash, jsonOrEmpty(resultDoc)); err != nil {
			return err
		}
		if err := auditTx(ctx, tx, "match_settled", "info", fmt.Sprintf("server:%d", serverID), &matchID, nil,
			map[string]any{"ranked": out.Ranked, "reason": out.Reason}); err != nil {
			return err
		}
		out.Players, err = loadSettled(ctx, tx, matchID)
		return err
	})
	switch {
	case errors.Is(err, ErrConflict):
		s.Audit(ctx, "result_conflict", "alert", fmt.Sprintf("server:%d", serverID), &matchID, nil,
			map[string]string{"note": "a different result arrived for a settled match; the first one stands"})
	case errors.Is(err, ErrForbidden):
		s.Audit(ctx, "result_wrong_server", "alert", fmt.Sprintf("server:%d", serverID), &matchID, nil,
			map[string]string{"note": "result from a server the match was not assigned to"})
	case errors.Is(err, ErrGone):
		s.Audit(ctx, "result_for_void", "warn", fmt.Sprintf("server:%d", serverID), &matchID, nil, nil)
	}
	return out, err
}

func validateEntries(entries []ResultEntry) error {
	if len(entries) < 1 || len(entries) > 6 {
		return fmt.Errorf("%w: 1 to 6 players", ErrBadRequest)
	}
	places := map[int]bool{}
	ids := map[int64]bool{}
	for _, e := range entries {
		if e.Place < 1 || e.Place > 6 || places[e.Place] || ids[e.PlayerID] {
			return fmt.Errorf("%w: places must be distinct, 1 to 6, and players listed once", ErrBadRequest)
		}
		places[e.Place] = true
		ids[e.PlayerID] = true
	}
	return nil
}

type seatRow struct {
	playerID int64
	seat     int
	scored   bool
}

func loadSeats(ctx context.Context, tx pgx.Tx, matchID int64) ([]seatRow, error) {
	rows, err := tx.Query(ctx, `SELECT player_id, seat, ranked FROM match_players WHERE match_id = $1 ORDER BY seat`, matchID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []seatRow
	for rows.Next() {
		var r seatRow
		if err := rows.Scan(&r.playerID, &r.seat, &r.scored); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func loadSettled(ctx context.Context, tx pgx.Tx, matchID int64) ([]SettledPlayer, error) {
	rows, err := tx.Query(ctx, `SELECT player_id, seat, ranked, COALESCE(final_place, 0), COALESCE(abandoned, false),
		COALESCE(points_before, 0), COALESCE(points_after, 0), COALESCE(applied_delta, 0)
		FROM match_players WHERE match_id = $1 ORDER BY seat`, matchID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SettledPlayer
	for rows.Next() {
		var p SettledPlayer
		if err := rows.Scan(&p.PlayerID, &p.Seat, &p.Scored, &p.FinalPlace, &p.Abandoned, &p.Before, &p.After, &p.Applied); err != nil {
			return nil, err
		}
		pts := p.After
		p.Division, p.DivisionName = ranking.Division(pts), ranking.DivisionName(pts)
		out = append(out, p)
	}
	return out, rows.Err()
}

// AnnulResult lists what an annulment reverted.
type AnnulResult struct {
	MatchID  int64
	Status   string // "annulled", or "void" for a match that was never settled
	Already  bool
	Reverted []Reverted
}

// Reverted is the change taken back from one player.
type Reverted struct {
	PlayerID int64 `json:"-"`
	Applied  int   `json:"applied_delta"`
	Before   int   `json:"points_before_revert"`
	After    int   `json:"points_after_revert"`
}

// AnnulMatch cancels a match. A settled match gets exactly the applied deltas taken back (points stay at or above 0);
// an open one becomes void. Annulling twice does nothing.
func (s *Store) AnnulMatch(ctx context.Context, matchID int64, reason, actor string) (AnnulResult, error) {
	res := AnnulResult{MatchID: matchID}
	err := s.withTx(ctx, func(tx pgx.Tx) error {
		res.Reverted = nil
		var status string
		err := tx.QueryRow(ctx, `SELECT status FROM matches WHERE match_id = $1 FOR UPDATE`, matchID).Scan(&status)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		switch status {
		case "annulled", "void":
			res.Status, res.Already = status, true
			return nil
		case "assigned":
			res.Status = "void"
			if _, err := tx.Exec(ctx, `UPDATE matches SET status = 'void', annul_reason = $2 WHERE match_id = $1`, matchID, reason); err != nil {
				return err
			}
			return auditTx(ctx, tx, "match_void", "warn", actor, &matchID, nil, map[string]string{"reason": reason})
		}
		res.Status = "annulled"
		rows, err := tx.Query(ctx, `SELECT player_id, applied_delta, rating_before, dev_before, vol_before FROM match_players
			WHERE match_id = $1 AND ranked AND applied_delta IS NOT NULL ORDER BY player_id`, matchID)
		if err != nil {
			return err
		}
		type row struct {
			id               int64
			applied          int
			rating, dev, vol float64
		}
		var list []row
		for rows.Next() {
			var r row
			if err := rows.Scan(&r.id, &r.applied, &r.rating, &r.dev, &r.vol); err != nil {
				rows.Close()
				return err
			}
			list = append(list, r)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}
		for _, r := range list {
			var points int
			var last *int64
			err := tx.QueryRow(ctx, `SELECT points, last_match_id FROM ratings WHERE player_id = $1 FOR UPDATE`, r.id).Scan(&points, &last)
			if errors.Is(err, pgx.ErrNoRows) {
				continue // the account was deleted
			}
			if err != nil {
				return err
			}
			after := ranking.Apply(points, -r.applied)
			if last != nil && *last == matchID {
				// Nothing was rated since: the hidden rating goes back too.
				_, err = tx.Exec(ctx, `UPDATE ratings SET points = $2, rating = $3, dev = $4, vol = $5,
					ranked_matches = GREATEST(ranked_matches - 1, 0), last_match_id = NULL, updated_at = $6 WHERE player_id = $1`,
					r.id, after, r.rating, r.dev, r.vol, s.Now())
			} else {
				_, err = tx.Exec(ctx, `UPDATE ratings SET points = $2, updated_at = $3 WHERE player_id = $1`, r.id, after, s.Now())
			}
			if err != nil {
				return err
			}
			res.Reverted = append(res.Reverted, Reverted{PlayerID: r.id, Applied: r.applied, Before: points, After: after})
		}
		if _, err := tx.Exec(ctx, `UPDATE matches SET status = 'annulled', annul_reason = $2 WHERE match_id = $1`, matchID, reason); err != nil {
			return err
		}
		return auditTx(ctx, tx, "match_annulled", "warn", actor, &matchID, nil, map[string]any{"reason": reason, "players": len(res.Reverted)})
	})
	return res, err
}

// MatchInfo is the admin view of a match.
type MatchInfo struct {
	MatchID  int64
	ServerID int64
	Status   string
	Ranked   bool
	Reason   string
	Released bool
	Players  []SettledPlayer
}

// GetMatch loads a match for the admin endpoint.
func (s *Store) GetMatch(ctx context.Context, matchID int64) (MatchInfo, error) {
	m := MatchInfo{MatchID: matchID}
	err := s.withTx(ctx, func(tx pgx.Tx) error {
		err := tx.QueryRow(ctx, `SELECT server_id, status, ranked, rank_reason, released FROM matches WHERE match_id = $1`, matchID).
			Scan(&m.ServerID, &m.Status, &m.Ranked, &m.Reason, &m.Released)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		m.Players, err = loadSettled(ctx, tx, matchID)
		return err
	})
	return m, err
}

// StoreReplay saves the replay a game server uploads (compressed bytes, kept as given). The same bytes again are
// accepted; different bytes for the same match are ErrConflict. It returns whether a row was created.
func (s *Store) StoreReplay(ctx context.Context, matchID, serverID int64, format string, data []byte) (bool, error) {
	sum := sha256.Sum256(data)
	created := false
	err := s.withTx(ctx, func(tx pgx.Tx) error {
		var owner int64
		var status string
		err := tx.QueryRow(ctx, `SELECT server_id, status FROM matches WHERE match_id = $1 FOR UPDATE`, matchID).Scan(&owner, &status)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if owner != serverID {
			return ErrForbidden
		}
		if status == "void" {
			return ErrGone
		}
		var existing []byte
		err = tx.QueryRow(ctx, `SELECT sha256 FROM replays WHERE match_id = $1 LIMIT 1`, matchID).Scan(&existing)
		if err == nil {
			if string(existing) != string(sum[:]) {
				return ErrConflict
			}
			return nil
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		created = true
		_, err = tx.Exec(ctx, `INSERT INTO replays (match_id, created_at, format, sha256, data) VALUES ($1, $2, $3, $4, $5)`,
			matchID, s.Now(), format, sum[:], data)
		return err
	})
	if errors.Is(err, ErrConflict) {
		s.Audit(ctx, "replay_conflict", "alert", fmt.Sprintf("server:%d", serverID), &matchID, nil, nil)
	}
	return created, err
}

// GetReplay returns a stored replay.
func (s *Store) GetReplay(ctx context.Context, matchID int64) (format string, data []byte, err error) {
	err = s.pool.QueryRow(ctx, `SELECT format, data FROM replays WHERE match_id = $1 LIMIT 1`, matchID).Scan(&format, &data)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil, ErrNotFound
	}
	return format, data, err
}
