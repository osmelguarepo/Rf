package store

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"fuelrivals/backend/internal/ranking"
)

func jsonOrEmpty(v any) []byte {
	if v == nil {
		return []byte("{}")
	}
	b, err := json.Marshal(v)
	if err != nil {
		return []byte("{}")
	}
	return b
}

// Player is an account as the handlers see it.
type Player struct {
	ID      int64
	SteamID string // "" for guests
	Name    string
	Guest   bool
	Banned  bool
}

// Profile is what GET /me returns.
type Profile struct {
	PlayerID     string `json:"player_id"`
	SteamID      string `json:"steam_id,omitempty"`
	Name         string `json:"name"`
	Guest        bool   `json:"guest"`
	Ranked       bool   `json:"ranked"` // false for guests: they never score
	Points       int    `json:"points"`
	Division     int    `json:"division"`
	DivisionName string `json:"division_name"`
	ToNext       int    `json:"points_to_next"`
	Rank         int    `json:"rank"` // 1 = top of the leaderboard, 0 for guests
	Provisional  bool   `json:"provisional"`
	Matches      int    `json:"ranked_matches"`
	// Strength is the hidden rating for matching. It is returned only to services (see Handlers), never to players.
	Strength float64 `json:"-"`
}

// UpsertSteamPlayer creates or updates the account of a SteamID after a verified login and returns it. A banned
// SteamID (flag or ban hash, which survives deletion) gives ErrBanned.
func (s *Store) UpsertSteamPlayer(ctx context.Context, steamID, displayName string) (Player, error) {
	var p Player
	err := s.withTx(ctx, func(tx pgx.Tx) error {
		var banned bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM bans WHERE steam_hash = $1)`, s.banHash(steamID)).Scan(&banned); err != nil {
			return err
		}
		if banned {
			return ErrBanned
		}
		now := s.Now()
		err := tx.QueryRow(ctx, `
			INSERT INTO players (steam_id, name, last_login_at) VALUES ($1, $2, $3)
			ON CONFLICT (steam_id) DO UPDATE SET name = EXCLUDED.name, last_login_at = EXCLUDED.last_login_at
			RETURNING player_id, COALESCE(steam_id, ''), name, is_guest, banned`, steamID, displayName, now).
			Scan(&p.ID, &p.SteamID, &p.Name, &p.Guest, &p.Banned)
		if err != nil {
			return err
		}
		if p.Banned {
			return ErrBanned
		}
		_, err = tx.Exec(ctx, `INSERT INTO ratings (player_id) VALUES ($1) ON CONFLICT DO NOTHING`, p.ID)
		return err
	})
	return p, err
}

// CreateGuest makes an unranked guest account that lasts until `until`.
func (s *Store) CreateGuest(ctx context.Context, until time.Time) (Player, error) {
	var suffix [3]byte
	_, _ = rand.Read(suffix[:])
	name := fmt.Sprintf("G%02X%02X%02X", suffix[0], suffix[1], suffix[2])
	var p Player
	err := s.withTx(ctx, func(tx pgx.Tx) error {
		if err := tx.QueryRow(ctx, `INSERT INTO players (name, is_guest, last_login_at) VALUES ($1, true, $2)
			RETURNING player_id, name, is_guest`, name, s.Now()).Scan(&p.ID, &p.Name, &p.Guest); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `INSERT INTO guests (player_id, expires_at) VALUES ($1, $2)`, p.ID, until)
		return err
	})
	return p, err
}

// CreateSession gives the player a new session and ends the previous one: a player has one active session.
func (s *Store) CreateSession(ctx context.Context, playerID int64, kind string, ttl time.Duration) (token string, expires time.Time, err error) {
	token, hash := NewToken()
	expires = s.Now().Add(ttl)
	err = s.withTx(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `DELETE FROM sessions WHERE player_id = $1`, playerID); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `INSERT INTO sessions (token_hash, player_id, kind, created_at, expires_at) VALUES ($1, $2, $3, $4, $5)`,
			hash, playerID, kind, s.Now(), expires)
		return err
	})
	return token, expires, err
}

// PlayerBySession resolves a session token. Expired, unknown, banned and deleted accounts give ErrNotFound.
func (s *Store) PlayerBySession(ctx context.Context, token string) (Player, error) {
	var p Player
	err := s.pool.QueryRow(ctx, `
		SELECT p.player_id, COALESCE(p.steam_id, ''), p.name, p.is_guest, p.banned
		FROM sessions x JOIN players p USING (player_id)
		WHERE x.token_hash = $1 AND x.expires_at > $2 AND p.deleted_at IS NULL AND NOT p.banned`,
		HashToken(token), s.Now()).Scan(&p.ID, &p.SteamID, &p.Name, &p.Guest, &p.Banned)
	if errors.Is(err, pgx.ErrNoRows) {
		return Player{}, ErrNotFound
	}
	return p, err
}

// DeleteSession ends a session (logout).
func (s *Store) DeleteSession(ctx context.Context, token string) error {
	_, err := s.pool.Exec(ctx, `DELETE FROM sessions WHERE token_hash = $1`, HashToken(token))
	return err
}

// CreateExchangeCode makes the one-time code the OpenID return puts in the page's URL fragment.
func (s *Store) CreateExchangeCode(ctx context.Context, playerID int64, ttl time.Duration) (string, error) {
	code, hash := NewToken()
	_, err := s.pool.Exec(ctx, `INSERT INTO exchange_codes (code_hash, player_id, expires_at) VALUES ($1, $2, $3)`,
		hash, playerID, s.Now().Add(ttl))
	return code, err
}

// RedeemExchangeCode uses a code once: it is deleted whether or not it was still valid.
func (s *Store) RedeemExchangeCode(ctx context.Context, code string) (Player, error) {
	var p Player
	err := s.withTx(ctx, func(tx pgx.Tx) error {
		var id int64
		var exp time.Time
		err := tx.QueryRow(ctx, `DELETE FROM exchange_codes WHERE code_hash = $1 RETURNING player_id, expires_at`,
			HashToken(code)).Scan(&id, &exp)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if s.Now().After(exp) {
			return ErrExpired
		}
		err = tx.QueryRow(ctx, `SELECT player_id, COALESCE(steam_id, ''), name, is_guest, banned FROM players
			WHERE player_id = $1 AND deleted_at IS NULL AND NOT banned`, id).Scan(&p.ID, &p.SteamID, &p.Name, &p.Guest, &p.Banned)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		return err
	})
	if errors.Is(err, ErrExpired) {
		// The code is gone (the DELETE ran) but the transaction rolled back; delete it again.
		_, _ = s.pool.Exec(ctx, `DELETE FROM exchange_codes WHERE code_hash = $1`, HashToken(code))
	}
	return p, err
}

// Fresh makes the store a steam.NonceStore: it records an OpenID response nonce and says whether it was new.
func (s *Store) Fresh(ctx context.Context, nonce string, seenAt time.Time) (bool, error) {
	tag, err := s.pool.Exec(ctx, `INSERT INTO openid_nonces (nonce, seen_at) VALUES ($1, $2) ON CONFLICT DO NOTHING`, nonce, seenAt)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() == 1, nil
}

// Cleanup deletes what has expired: sessions, guests, exchange codes, old nonces and old pairings.
func (s *Store) Cleanup(ctx context.Context) error {
	now := s.Now()
	stmts := []struct {
		q    string
		args []any
	}{
		{`DELETE FROM sessions WHERE expires_at < $1`, []any{now}},
		{`DELETE FROM exchange_codes WHERE expires_at < $1`, []any{now}},
		{`DELETE FROM openid_nonces WHERE seen_at < $1`, []any{now.Add(-time.Hour)}},
		{`DELETE FROM pairings WHERE day < $1`, []any{now.UTC().AddDate(0, 0, -2)}},
		// Expired guests with no match history disappear; those with history are kept as anonymous rows.
		{`DELETE FROM players p USING guests g WHERE g.player_id = p.player_id AND g.expires_at < $1
		  AND NOT EXISTS (SELECT 1 FROM match_players m WHERE m.player_id = p.player_id)`, []any{now}},
		// Logs and audit are kept 30 days (SPEC_ONLINE 16.3), alerts longer.
		{`DELETE FROM audit WHERE at < $1 AND severity <> 'alert'`, []any{now.AddDate(0, 0, -30)}},
	}
	for _, st := range stmts {
		if _, err := s.pool.Exec(ctx, st.q, st.args...); err != nil {
			return err
		}
	}
	return nil
}

// ProfileOf builds GET /me for a player.
func (s *Store) ProfileOf(ctx context.Context, p Player) (Profile, error) {
	prof := Profile{PlayerID: fmt.Sprint(p.ID), SteamID: p.SteamID, Name: p.Name, Guest: p.Guest, ToNext: -1}
	if p.Guest {
		prof.DivisionName = ranking.DivisionName(0)
		return prof, nil
	}
	var dev, strength float64
	err := s.pool.QueryRow(ctx, `SELECT points, ranked_matches, dev, rating FROM ratings WHERE player_id = $1`, p.ID).
		Scan(&prof.Points, &prof.Matches, &dev, &strength)
	if errors.Is(err, pgx.ErrNoRows) {
		return prof, ErrNotFound
	}
	if err != nil {
		return prof, err
	}
	prof.Ranked = true
	prof.Division = ranking.Division(prof.Points)
	prof.DivisionName = ranking.DivisionName(prof.Points)
	prof.ToNext = ranking.PointsToNext(prof.Points)
	prof.Strength = strength
	prof.Provisional = ranking.Skill{Rating: strength, Dev: dev}.Provisional(prof.Matches)
	if prof.Matches == 0 {
		return prof, nil // not on the leaderboard until the first ranked match
	}
	err = s.pool.QueryRow(ctx, `SELECT 1 + count(*) FROM ratings r JOIN players q USING (player_id)
		WHERE r.points > $1 AND r.ranked_matches > 0 AND q.deleted_at IS NULL AND NOT q.banned`, prof.Points).Scan(&prof.Rank)
	return prof, err
}

// LeaderboardEntry is one line of GET /leaderboard.
type LeaderboardEntry struct {
	Rank         int    `json:"rank"`
	PlayerID     string `json:"player_id"`
	Name         string `json:"name"`
	Points       int    `json:"points"`
	Division     int    `json:"division"`
	DivisionName string `json:"division_name"`
}

// Leaderboard returns the best `limit` ranked accounts (1 to 100), ties sharing a rank. Accounts that never played a
// ranked match are left out, and so are banned and deleted ones.
func (s *Store) Leaderboard(ctx context.Context, limit int) ([]LeaderboardEntry, error) {
	if limit < 1 {
		limit = 10
	}
	if limit > 100 {
		limit = 100
	}
	rows, err := s.pool.Query(ctx, `
		SELECT rank() OVER (ORDER BY r.points DESC), p.player_id, p.name, r.points
		FROM ratings r JOIN players p USING (player_id)
		WHERE p.deleted_at IS NULL AND NOT p.banned AND r.ranked_matches > 0
		ORDER BY r.points DESC, p.player_id LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []LeaderboardEntry{}
	for rows.Next() {
		var e LeaderboardEntry
		var id int64
		if err := rows.Scan(&e.Rank, &id, &e.Name, &e.Points); err != nil {
			return nil, err
		}
		e.PlayerID = fmt.Sprint(id)
		e.Division = ranking.Division(e.Points)
		e.DivisionName = ranking.DivisionName(e.Points)
		out = append(out, e)
	}
	return out, rows.Err()
}

// BanPlayer bans an account: flag, salted hash (survives deletion) and its session.
func (s *Store) BanPlayer(ctx context.Context, playerID int64, reason, actor string) error {
	return s.withTx(ctx, func(tx pgx.Tx) error {
		var steamID *string
		err := tx.QueryRow(ctx, `UPDATE players SET banned = true WHERE player_id = $1 RETURNING steam_id`, playerID).Scan(&steamID)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if steamID != nil {
			if _, err := tx.Exec(ctx, `INSERT INTO bans (steam_hash, reason) VALUES ($1, $2) ON CONFLICT DO NOTHING`,
				s.banHash(*steamID), reason); err != nil {
				return err
			}
		}
		if _, err := tx.Exec(ctx, `DELETE FROM sessions WHERE player_id = $1`, playerID); err != nil {
			return err
		}
		return auditTx(ctx, tx, "ban", "warn", actor, nil, &playerID, map[string]string{"reason": reason})
	})
}

// AddReport stores a report of one player about another.
func (s *Store) AddReport(ctx context.Context, reporter, target int64, matchID *int64, reason string) error {
	var exists bool
	if err := s.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM players WHERE player_id = $1 AND deleted_at IS NULL)`, target).Scan(&exists); err != nil {
		return err
	}
	if !exists {
		return ErrNotFound
	}
	_, err := s.pool.Exec(ctx, `INSERT INTO reports (reporter, target, match_id, reason) VALUES ($1, $2, $3, $4)`,
		reporter, target, matchID, reason)
	return err
}
