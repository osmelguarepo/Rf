package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
)

// DeleteAccount erases a player (SPEC_ONLINE 16.3): sessions, rating, match history, reports, pairings and guest data go;
// the players row stays as an anonymous tombstone (no SteamID, name "DELETED") so ids in kept replays and audit rows
// point at nothing. The salted ban hash, if the account was banned, stays so a ban cannot be dodged by deleting.
// A player in an open match cannot be deleted (ErrBusy): finish or leave the match first.
func (s *Store) DeleteAccount(ctx context.Context, playerID int64) error {
	return s.withTx(ctx, func(tx pgx.Tx) error {
		var deleted *time.Time
		err := tx.QueryRow(ctx, `SELECT deleted_at FROM players WHERE player_id = $1 FOR UPDATE`, playerID).Scan(&deleted)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if deleted != nil {
			return nil // already deleted
		}
		var busy bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM match_players mp JOIN matches m USING (match_id)
			WHERE mp.player_id = $1 AND m.status = 'assigned' AND NOT m.released)`, playerID).Scan(&busy); err != nil {
			return err
		}
		if busy {
			return ErrBusy
		}
		for _, q := range []string{
			`DELETE FROM sessions WHERE player_id = $1`,
			`DELETE FROM exchange_codes WHERE player_id = $1`,
			`DELETE FROM ratings WHERE player_id = $1`,
			`DELETE FROM match_players WHERE player_id = $1`,
			`DELETE FROM reports WHERE reporter = $1 OR target = $1`,
			`DELETE FROM pairings WHERE a = $1 OR b = $1`,
			`DELETE FROM guests WHERE player_id = $1`,
			`UPDATE audit SET player_id = NULL, detail = '{}' WHERE player_id = $1`,
		} {
			if _, err := tx.Exec(ctx, q, playerID); err != nil {
				return err
			}
		}
		if _, err := tx.Exec(ctx, `UPDATE players SET steam_id = NULL, name = 'DELETED', is_guest = false, deleted_at = $2
			WHERE player_id = $1`, playerID, s.Now()); err != nil {
			return err
		}
		return auditTx(ctx, tx, "account_deleted", "info", "player", nil, nil, nil)
	})
}

// Export is the data kept about a player (GET /account/export).
type Export struct {
	ExportedAt time.Time        `json:"exported_at"`
	Player     map[string]any   `json:"player"`
	Rating     map[string]any   `json:"rating,omitempty"`
	Matches    []map[string]any `json:"matches"`
	Reports    []map[string]any `json:"reports_made"`
	Notes      string           `json:"notes"`
}

// ExportAccount gathers everything stored about the player. IP addresses are not stored, so there are none to list.
func (s *Store) ExportAccount(ctx context.Context, playerID int64) (Export, error) {
	ex := Export{ExportedAt: s.Now().UTC(), Matches: []map[string]any{}, Reports: []map[string]any{},
		Notes: "No IP addresses are stored. Replays contain no personal data."}
	var steamID *string
	var name string
	var guest bool
	var created time.Time
	var last *time.Time
	err := s.pool.QueryRow(ctx, `SELECT steam_id, name, is_guest, created_at, last_login_at FROM players
		WHERE player_id = $1 AND deleted_at IS NULL`, playerID).Scan(&steamID, &name, &guest, &created, &last)
	if errors.Is(err, pgx.ErrNoRows) {
		return ex, ErrNotFound
	}
	if err != nil {
		return ex, err
	}
	ex.Player = map[string]any{"player_id": fmt.Sprint(playerID), "steam_id": steamID, "name": name, "guest": guest,
		"created_at": created.UTC(), "last_login_at": last}
	var points, ranked int
	var rating, dev, vol float64
	err = s.pool.QueryRow(ctx, `SELECT points, ranked_matches, rating, dev, vol FROM ratings WHERE player_id = $1`, playerID).
		Scan(&points, &ranked, &rating, &dev, &vol)
	if err == nil {
		ex.Rating = map[string]any{"points": points, "ranked_matches": ranked, "hidden_rating": rating, "hidden_deviation": dev, "hidden_volatility": vol}
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return ex, err
	}
	rows, err := s.pool.Query(ctx, `SELECT mp.match_id, m.status, m.created_at, mp.seat, mp.ranked, mp.abandoned, mp.final_place,
		mp.points_before, mp.points_after, mp.applied_delta FROM match_players mp JOIN matches m USING (match_id)
		WHERE mp.player_id = $1 ORDER BY mp.match_id`, playerID)
	if err != nil {
		return ex, err
	}
	for rows.Next() {
		var id int64
		var status string
		var at time.Time
		var seat int
		var scored bool
		var ab *bool
		var fp, pb, pa, ad *int
		if err := rows.Scan(&id, &status, &at, &seat, &scored, &ab, &fp, &pb, &pa, &ad); err != nil {
			rows.Close()
			return ex, err
		}
		ex.Matches = append(ex.Matches, map[string]any{"match_id": fmt.Sprint(id), "status": status, "at": at.UTC(), "seat": seat,
			"scored": scored, "abandoned": ab, "final_place": fp, "points_before": pb, "points_after": pa, "applied_delta": ad})
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return ex, err
	}
	rrows, err := s.pool.Query(ctx, `SELECT report_id, target, match_id, reason, created_at FROM reports WHERE reporter = $1 ORDER BY report_id`, playerID)
	if err != nil {
		return ex, err
	}
	defer rrows.Close()
	for rrows.Next() {
		var id, target int64
		var match *int64
		var reason string
		var at time.Time
		if err := rrows.Scan(&id, &target, &match, &reason, &at); err != nil {
			return ex, err
		}
		ex.Reports = append(ex.Reports, map[string]any{"report_id": id, "target_player_id": fmt.Sprint(target), "match_id": match,
			"reason": reason, "at": at.UTC()})
	}
	return ex, rrows.Err()
}
