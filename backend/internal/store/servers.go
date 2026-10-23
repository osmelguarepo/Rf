package store

import (
	"context"
	"crypto/hmac"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
)

// Server is a registered game server.
type Server struct {
	ID            int64
	Name          string
	Region        string
	URL           string
	Capacity      int
	KeyVersion    int
	Draining      bool
	ActiveMatches int
}

// IDString is the id as text, as it travels in tickets and headers.
func (s Server) IDString() string { return strconv.FormatInt(s.ID, 10) }

// RegisterServer adds a game server, or, if the name exists, replaces its settings and rotates its key. The key is
// returned as hex and is not stored (see ServerKey).
func (s *Store) RegisterServer(ctx context.Context, name, region, url string, capacity int) (Server, string, error) {
	var sv Server
	err := s.pool.QueryRow(ctx, `
		INSERT INTO servers (name, region, url, capacity) VALUES ($1, $2, $3, $4)
		ON CONFLICT (name) DO UPDATE SET region = EXCLUDED.region, url = EXCLUDED.url, capacity = EXCLUDED.capacity,
			key_version = servers.key_version + 1, lease_expires_at = NULL, draining = false, drain_requested = false
		RETURNING server_id, name, region, url, capacity, key_version, draining, active_matches`,
		name, region, url, capacity).
		Scan(&sv.ID, &sv.Name, &sv.Region, &sv.URL, &sv.Capacity, &sv.KeyVersion, &sv.Draining, &sv.ActiveMatches)
	if err != nil {
		return Server{}, "", err
	}
	return sv, ServerKeyHex(s.cfg.MasterKey, sv.ID, sv.KeyVersion), nil
}

// AuthServer checks a game server's id and hex key. Any failure is ErrForbidden, so a caller cannot tell which part
// was wrong.
func (s *Store) AuthServer(ctx context.Context, idText, keyHex string) (Server, error) {
	id, err := strconv.ParseInt(idText, 10, 64)
	if err != nil || id <= 0 {
		return Server{}, ErrForbidden
	}
	key, err := hex.DecodeString(keyHex)
	if err != nil || len(key) != 32 {
		return Server{}, ErrForbidden
	}
	var sv Server
	err = s.pool.QueryRow(ctx, `SELECT server_id, name, region, url, capacity, key_version, draining, active_matches
		FROM servers WHERE server_id = $1`, id).
		Scan(&sv.ID, &sv.Name, &sv.Region, &sv.URL, &sv.Capacity, &sv.KeyVersion, &sv.Draining, &sv.ActiveMatches)
	if errors.Is(err, pgx.ErrNoRows) {
		return Server{}, ErrForbidden
	}
	if err != nil {
		return Server{}, err
	}
	if !hmac.Equal(key, ServerKey(s.cfg.MasterKey, sv.ID, sv.KeyVersion)) {
		return Server{}, ErrForbidden
	}
	return sv, nil
}

// ServerByID loads a registered server.
func (s *Store) ServerByID(ctx context.Context, id int64) (Server, error) {
	var sv Server
	err := s.pool.QueryRow(ctx, `SELECT server_id, name, region, url, capacity, key_version, draining, active_matches
		FROM servers WHERE server_id = $1`, id).
		Scan(&sv.ID, &sv.Name, &sv.Region, &sv.URL, &sv.Capacity, &sv.KeyVersion, &sv.Draining, &sv.ActiveMatches)
	if errors.Is(err, pgx.ErrNoRows) {
		return Server{}, ErrNotFound
	}
	return sv, err
}

// KeyOf is the raw key of a server, to sign its tickets.
func (s *Store) KeyOf(sv Server) []byte { return ServerKey(s.cfg.MasterKey, sv.ID, sv.KeyVersion) }

// Heartbeat is what a game server reports every few seconds.
type Heartbeat struct {
	Capacity      int             `json:"capacity"`
	ActiveMatches int             `json:"active_matches"`
	Draining      bool            `json:"draining"`
	SimHash       string          `json:"sim_hash"`
	GameVersion   string          `json:"game_version"`
	Metrics       json.RawMessage `json:"metrics"`
}

// Validate checks the sizes and types of a heartbeat.
func (h Heartbeat) Validate() error {
	if h.Capacity < 0 || h.Capacity > 10000 || h.ActiveMatches < 0 || h.ActiveMatches > 100000 {
		return fmt.Errorf("%w: capacity or active_matches out of range", ErrBadRequest)
	}
	if len(h.SimHash) > 64 || len(h.GameVersion) > 32 {
		return fmt.Errorf("%w: hash or version too long", ErrBadRequest)
	}
	if len(h.Metrics) > 4096 {
		return fmt.Errorf("%w: metrics larger than 4 KiB", ErrBadRequest)
	}
	if len(h.Metrics) > 0 {
		var obj map[string]any
		if json.Unmarshal(h.Metrics, &obj) != nil {
			return fmt.Errorf("%w: metrics must be a JSON object", ErrBadRequest)
		}
	}
	return nil
}

// RecordHeartbeat stores the metrics and renews the lease until now + lease.
func (s *Store) RecordHeartbeat(ctx context.Context, serverID int64, h Heartbeat, lease time.Duration) error {
	metrics := []byte(h.Metrics)
	if len(metrics) == 0 {
		metrics = []byte("{}")
	}
	now := s.Now()
	_, err := s.pool.Exec(ctx, `UPDATE servers SET capacity = $2, active_matches = $3, draining = ($4 OR drain_requested), sim_hash = $5,
		game_version = $6, metrics = $7, last_heartbeat = $8, lease_expires_at = $9 WHERE server_id = $1`,
		serverID, h.Capacity, h.ActiveMatches, h.Draining, h.SimHash, h.GameVersion, metrics, now, now.Add(lease))
	return err
}

// ExpireResult counts what ExpireLeases did.
type ExpireResult struct {
	Released int // matches whose players were freed because their server went silent
	Voided   int // matches voided without settlement after VoidAfter
}

// ExpireLeases frees the players of servers whose lease ended (their matches stay open for a late result) and voids,
// without settling, the open matches of a silent server older than voidAfter (SPEC_ONLINE 16.2).
func (s *Store) ExpireLeases(ctx context.Context, voidAfter time.Duration) (ExpireResult, error) {
	var res ExpireResult
	now := s.Now()
	err := s.withTx(ctx, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			UPDATE matches m SET released = true
			FROM servers sv
			WHERE m.server_id = sv.server_id AND m.status = 'assigned' AND NOT m.released
			  AND (sv.lease_expires_at IS NULL OR sv.lease_expires_at < $1)
			RETURNING m.match_id`, now)
		if err != nil {
			return err
		}
		var released []int64
		for rows.Next() {
			var id int64
			if err := rows.Scan(&id); err != nil {
				return err
			}
			released = append(released, id)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}
		res.Released = len(released)
		for _, id := range released {
			id := id
			if err := auditTx(ctx, tx, "lease_expired", "warn", "system", &id, nil, nil); err != nil {
				return err
			}
		}
		vrows, err := tx.Query(ctx, `
			UPDATE matches m SET status = 'void', annul_reason = 'server silent'
			FROM servers sv
			WHERE m.server_id = sv.server_id AND m.status = 'assigned' AND m.released
			  AND m.created_at < $1 AND (sv.lease_expires_at IS NULL OR sv.lease_expires_at < $2)
			RETURNING m.match_id`, now.Add(-voidAfter), now)
		if err != nil {
			return err
		}
		var voided []int64
		for vrows.Next() {
			var id int64
			if err := vrows.Scan(&id); err != nil {
				return err
			}
			voided = append(voided, id)
		}
		vrows.Close()
		if err := vrows.Err(); err != nil {
			return err
		}
		res.Voided = len(voided)
		for _, id := range voided {
			id := id
			if err := auditTx(ctx, tx, "match_void", "warn", "system", &id, nil, map[string]string{"reason": "server silent"}); err != nil {
				return err
			}
		}
		return nil
	})
	return res, err
}
