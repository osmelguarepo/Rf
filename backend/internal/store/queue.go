package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
)

// ServerState is a registered game server as the matchmaker and the admin tool see it.
type ServerState struct {
	Server
	SimHash        string
	GameVersion    string
	LeaseAlive     bool
	OpenMatches    int // matches assigned to it that are neither settled, void nor released
	DrainRequested bool
	LastHeartbeat  *time.Time
}

// ListServers returns every registered server with its lease state and the number of open matches.
func (s *Store) ListServers(ctx context.Context) ([]ServerState, error) {
	now := s.Now()
	rows, err := s.pool.Query(ctx, `SELECT sv.server_id, sv.name, sv.region, sv.url, sv.capacity, sv.key_version, sv.draining,
		sv.active_matches, sv.sim_hash, sv.game_version, sv.drain_requested, sv.last_heartbeat,
		COALESCE(sv.lease_expires_at > $1, false),
		(SELECT count(*) FROM matches m WHERE m.server_id = sv.server_id AND m.status = 'assigned' AND NOT m.released)
		FROM servers sv ORDER BY sv.server_id`, now)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []ServerState
	for rows.Next() {
		var x ServerState
		if err := rows.Scan(&x.ID, &x.Name, &x.Region, &x.URL, &x.Capacity, &x.KeyVersion, &x.Draining, &x.ActiveMatches,
			&x.SimHash, &x.GameVersion, &x.DrainRequested, &x.LastHeartbeat, &x.LeaseAlive, &x.OpenMatches); err != nil {
			return nil, err
		}
		out = append(out, x)
	}
	return out, rows.Err()
}

// SetDrain asks (or stops asking) a game server to drain. The next heartbeat tells the server; new matches are not
// assigned to it from now on, the ones running finish.
func (s *Store) SetDrain(ctx context.Context, serverID int64, drain bool) error {
	return s.withTx(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE servers SET drain_requested = $2, draining = $2 WHERE server_id = $1`, serverID, drain)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		kind := "server_drain"
		if !drain {
			kind = "server_undrain"
		}
		return auditTx(ctx, tx, kind, "info", "admin", nil, nil, map[string]any{"server_id": serverID})
	})
}

// DrainRequested says whether an operator asked the server to drain (the heartbeat reply carries it).
func (s *Store) DrainRequested(ctx context.Context, serverID int64) (bool, error) {
	var d bool
	err := s.pool.QueryRow(ctx, `SELECT drain_requested FROM servers WHERE server_id = $1`, serverID).Scan(&d)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, ErrNotFound
	}
	return d, err
}

// ReserveMatchID takes the next match id, so the matchmaker can name a match when it is found, before it starts.
func (s *Store) ReserveMatchID(ctx context.Context) (int64, error) {
	var id int64
	err := s.pool.QueryRow(ctx, `SELECT nextval(pg_get_serial_sequence('matches', 'match_id'))`).Scan(&id)
	return id, err
}

// PlayerOpenMatch returns the match the player is in (assigned, not released), if any.
func (s *Store) PlayerOpenMatch(ctx context.Context, playerID int64) (int64, bool, error) {
	var id int64
	err := s.pool.QueryRow(ctx, `SELECT m.match_id FROM match_players mp JOIN matches m USING (match_id)
		WHERE mp.player_id = $1 AND m.status = 'assigned' AND NOT m.released AND mp.left_at IS NULL
		ORDER BY m.match_id DESC LIMIT 1`, playerID).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, false, nil
	}
	return id, err == nil, err
}

// Penalty is a player's queue penalty state.
type Penalty struct {
	Strikes     int
	LastAt      time.Time
	BannedUntil time.Time // zero: not banned
}

// LoadPenalty reads the stored counters (zero value if none).
func (s *Store) LoadPenalty(ctx context.Context, playerID int64) (Penalty, error) {
	var p Penalty
	var until *time.Time
	err := s.pool.QueryRow(ctx, `SELECT strikes, last_at, banned_until FROM leave_strikes WHERE player_id = $1`, playerID).
		Scan(&p.Strikes, &p.LastAt, &until)
	if errors.Is(err, pgx.ErrNoRows) {
		return Penalty{}, nil
	}
	if until != nil {
		p.BannedUntil = *until
	}
	return p, err
}

// SavePenalty stores the counters.
func (s *Store) SavePenalty(ctx context.Context, playerID int64, p Penalty) error {
	var until *time.Time
	if !p.BannedUntil.IsZero() {
		until = &p.BannedUntil
	}
	_, err := s.pool.Exec(ctx, `INSERT INTO leave_strikes (player_id, strikes, last_at, banned_until) VALUES ($1, $2, $3, $4)
		ON CONFLICT (player_id) DO UPDATE SET strikes = EXCLUDED.strikes, last_at = EXCLUDED.last_at, banned_until = EXCLUDED.banned_until`,
		playerID, p.Strikes, p.LastAt, until)
	return err
}

// ClearPenalty forgets a player's strikes (admin).
func (s *Store) ClearPenalty(ctx context.Context, playerID int64) error {
	_, err := s.pool.Exec(ctx, `DELETE FROM leave_strikes WHERE player_id = $1`, playerID)
	return err
}

// JoinInfo is what GET /match/{id}/join needs to know about a player's seat.
type JoinInfo struct {
	MatchID      int64
	ServerID     int64
	Status       string
	Released     bool
	Seed         int64
	Seat         int
	PlayerID     int64
	SteamID      string
	Name         string
	Guest        bool
	JoinIssuedAt *time.Time
	LeftAt       *time.Time
}

// SeatOf loads the seat of a player in a match. A player who is not in the match gives ErrNotFound.
func (s *Store) SeatOf(ctx context.Context, matchID, playerID int64) (JoinInfo, error) {
	var j JoinInfo
	err := s.pool.QueryRow(ctx, `SELECT m.match_id, m.server_id, m.status, m.released, m.seed, mp.seat, p.player_id,
		COALESCE(p.steam_id, ''), p.name, p.is_guest, mp.join_issued_at, mp.left_at
		FROM match_players mp JOIN matches m USING (match_id) JOIN players p ON p.player_id = mp.player_id
		WHERE mp.match_id = $1 AND mp.player_id = $2`, matchID, playerID).
		Scan(&j.MatchID, &j.ServerID, &j.Status, &j.Released, &j.Seed, &j.Seat, &j.PlayerID, &j.SteamID, &j.Name, &j.Guest, &j.JoinIssuedAt, &j.LeftAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return JoinInfo{}, ErrNotFound
	}
	return j, err
}

// MarkJoinIssued records the moment the first ticket of this seat was issued and returns it. Asking again returns the
// first moment, so the caller can re-sign the same ticket while it is still valid and refuse afterwards.
func (s *Store) MarkJoinIssued(ctx context.Context, matchID, playerID int64) (time.Time, error) {
	var at time.Time
	err := s.pool.QueryRow(ctx, `UPDATE match_players SET join_issued_at = COALESCE(join_issued_at, $3)
		WHERE match_id = $1 AND player_id = $2 RETURNING join_issued_at`, matchID, playerID, s.Now()).Scan(&at)
	if errors.Is(err, pgx.ErrNoRows) {
		return at, ErrNotFound
	}
	return at, err
}

// LeaveResult says what POST /match/{id}/leave did.
type LeaveResult struct {
	Already bool   // the player had already left
	Joined  bool   // a ticket had been issued: the player may be in the race, so this is an abandon
	Voided  bool   // every human left and the match had not been settled: it became void and the others were freed
	Status  string // the match status afterwards
}

// MarkLeft records that a player left a match. When no human is left in an open match, it is voided so nobody stays
// "in a match" forever.
func (s *Store) MarkLeft(ctx context.Context, matchID, playerID int64) (LeaveResult, error) {
	var res LeaveResult
	err := s.withTx(ctx, func(tx pgx.Tx) error {
		res = LeaveResult{}
		var left, issued *time.Time
		err := tx.QueryRow(ctx, `SELECT m.status, mp.left_at, mp.join_issued_at FROM match_players mp
			JOIN matches m USING (match_id) WHERE mp.match_id = $1 AND mp.player_id = $2 FOR UPDATE OF m, mp`, matchID, playerID).
			Scan(&res.Status, &left, &issued)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		res.Joined = issued != nil
		if left != nil {
			res.Already = true
			return nil
		}
		if _, err := tx.Exec(ctx, `UPDATE match_players SET left_at = $3 WHERE match_id = $1 AND player_id = $2`,
			matchID, playerID, s.Now()); err != nil {
			return err
		}
		if res.Status != "assigned" {
			return nil
		}
		var remaining int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM match_players WHERE match_id = $1 AND left_at IS NULL`, matchID).Scan(&remaining); err != nil {
			return err
		}
		if remaining == 0 {
			if _, err := tx.Exec(ctx, `UPDATE matches SET status = 'void', annul_reason = 'all players left' WHERE match_id = $1`, matchID); err != nil {
				return err
			}
			res.Voided, res.Status = true, "void"
			return auditTx(ctx, tx, "match_void", "info", "system", &matchID, nil, map[string]string{"reason": "all players left"})
		}
		return nil
	})
	return res, err
}

// MatchSummary is one line of the admin match list.
type MatchSummary struct {
	MatchID   int64     `json:"-"`
	ServerID  int64     `json:"-"`
	Status    string    `json:"status"`
	Ranked    bool      `json:"ranked"`
	Reason    string    `json:"rank_reason"`
	Humans    int       `json:"humans"`
	Bots      int       `json:"bots"`
	Released  bool      `json:"released"`
	CreatedAt time.Time `json:"created_at"`
}

// ListMatches returns the newest matches, optionally only those with a status ("" for all), up to limit (1 to 500).
func (s *Store) ListMatches(ctx context.Context, status string, limit int) ([]MatchSummary, error) {
	if limit < 1 || limit > 500 {
		limit = 50
	}
	rows, err := s.pool.Query(ctx, `SELECT match_id, server_id, status, ranked, rank_reason, humans, bots, released, created_at
		FROM matches WHERE ($1 = '' OR status = $1) ORDER BY match_id DESC LIMIT $2`, status, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []MatchSummary{}
	for rows.Next() {
		var m MatchSummary
		if err := rows.Scan(&m.MatchID, &m.ServerID, &m.Status, &m.Ranked, &m.Reason, &m.Humans, &m.Bots, &m.Released, &m.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// MatchHumans lists the player ids of a match (admin tool, load bot).
func (s *Store) MatchHumans(ctx context.Context, matchID int64) ([]int64, error) {
	rows, err := s.pool.Query(ctx, `SELECT player_id FROM match_players WHERE match_id = $1 ORDER BY seat`, matchID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out = append(out, id)
	}
	return out, rows.Err()
}

// UnbanPlayer lifts a ban (flag and the salted hash).
func (s *Store) UnbanPlayer(ctx context.Context, playerID int64, actor string) error {
	return s.withTx(ctx, func(tx pgx.Tx) error {
		var steamID *string
		err := tx.QueryRow(ctx, `UPDATE players SET banned = false WHERE player_id = $1 RETURNING steam_id`, playerID).Scan(&steamID)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if steamID != nil {
			if _, err := tx.Exec(ctx, `DELETE FROM bans WHERE steam_hash = $1`, s.banHash(*steamID)); err != nil {
				return err
			}
		}
		if _, err := tx.Exec(ctx, `DELETE FROM leave_strikes WHERE player_id = $1`, playerID); err != nil {
			return err
		}
		return auditTx(ctx, tx, "unban", "info", actor, nil, &playerID, nil)
	})
}

// QueueProfile is what the queue needs to know about a player.
type QueueProfile struct {
	Points int
	Rating float64
	Guest  bool
}

// QueueProfileOf reads the points and the hidden rating (guests: 0 points, the default rating).
func (s *Store) QueueProfileOf(ctx context.Context, p Player) (QueueProfile, error) {
	if p.Guest {
		return QueueProfile{Rating: 1500, Guest: true}, nil
	}
	q := QueueProfile{}
	err := s.pool.QueryRow(ctx, `SELECT points, rating FROM ratings WHERE player_id = $1`, p.ID).Scan(&q.Points, &q.Rating)
	if errors.Is(err, pgx.ErrNoRows) {
		return q, fmt.Errorf("%w: no rating row", ErrNotFound)
	}
	return q, err
}
