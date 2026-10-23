// Package store is the PostgreSQL layer of the API: schema migrations and every query. Handlers never write SQL.
package store

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"embed"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed migrations/*.sql
var migrationFiles embed.FS

// Errors the handlers translate into HTTP statuses.
var (
	ErrNotFound   = errors.New("not found")
	ErrBanned     = errors.New("account banned")
	ErrBusy       = errors.New("a match is in progress")
	ErrConflict   = errors.New("a different result was already settled")
	ErrForbidden  = errors.New("not allowed")
	ErrBadRequest = errors.New("bad request")
	ErrGone       = errors.New("match is void or annulled")
	ErrDraining   = errors.New("server is not accepting matches")
	ErrExpired    = errors.New("expired")
)

// Config holds the secrets the store needs.
type Config struct {
	MasterKey []byte // derives the game server keys
	BanSalt   []byte // salts the hashes of banned SteamIDs
}

// Store wraps the connection pool.
type Store struct {
	pool *pgxpool.Pool
	cfg  Config
	// Now is the clock (replaceable in tests).
	Now func() time.Time
}

// Open connects and checks the connection. Call Migrate next.
func Open(ctx context.Context, databaseURL string, cfg Config) (*Store, error) {
	pool, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		return nil, err
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, err
	}
	return &Store{pool: pool, cfg: cfg, Now: time.Now}, nil
}

// New wraps an existing pool (tests).
func New(pool *pgxpool.Pool, cfg Config) *Store { return &Store{pool: pool, cfg: cfg, Now: time.Now} }

// Close releases the pool.
func (s *Store) Close() { s.pool.Close() }

// Ping checks the database is reachable.
func (s *Store) Ping(ctx context.Context) error { return s.pool.Ping(ctx) }

// Pool exposes the pool for tests.
func (s *Store) Pool() *pgxpool.Pool { return s.pool }

// Migrate applies the embedded migrations in order, each in its own transaction, under an advisory lock so several
// instances starting together do not race.
func (s *Store) Migrate(ctx context.Context) error {
	conn, err := s.pool.Acquire(ctx)
	if err != nil {
		return err
	}
	defer conn.Release()
	const lockID = 7266417001
	if _, err := conn.Exec(ctx, `SELECT pg_advisory_lock($1)`, lockID); err != nil {
		return err
	}
	defer conn.Exec(context.Background(), `SELECT pg_advisory_unlock($1)`, lockID) //nolint:errcheck

	if _, err := conn.Exec(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
		version integer PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())`); err != nil {
		return err
	}
	entries, err := fs.ReadDir(migrationFiles, "migrations")
	if err != nil {
		return err
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		names = append(names, e.Name())
	}
	sort.Strings(names)
	for _, name := range names {
		version, err := strconv.Atoi(strings.SplitN(name, "_", 2)[0])
		if err != nil {
			return fmt.Errorf("migration %s: name must start with a number", name)
		}
		var done bool
		if err := conn.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE version = $1)`, version).Scan(&done); err != nil {
			return err
		}
		if done {
			continue
		}
		sqlText, err := migrationFiles.ReadFile("migrations/" + name)
		if err != nil {
			return err
		}
		tx, err := conn.Begin(ctx)
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, string(sqlText)); err != nil {
			_ = tx.Rollback(ctx)
			return fmt.Errorf("migration %s: %w", name, err)
		}
		if _, err := tx.Exec(ctx, `INSERT INTO schema_migrations (version) VALUES ($1)`, version); err != nil {
			_ = tx.Rollback(ctx)
			return err
		}
		if err := tx.Commit(ctx); err != nil {
			return err
		}
	}
	return nil
}

// EnsureReplayPartitions creates the monthly partitions of the replays table for the current month and the next
// `ahead` months. A partition that cannot be created (rows of that month already sit in the default partition) is
// reported in the returned error but does not stop the others.
func (s *Store) EnsureReplayPartitions(ctx context.Context, ahead int) error {
	now := s.Now().UTC()
	first := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, time.UTC)
	var errs []error
	for i := 0; i <= ahead; i++ {
		from := first.AddDate(0, i, 0)
		to := from.AddDate(0, 1, 0)
		name := "replays_" + from.Format("2006_01")
		q := fmt.Sprintf(`CREATE TABLE IF NOT EXISTS %s PARTITION OF replays FOR VALUES FROM ('%s') TO ('%s')`,
			name, from.Format("2006-01-02"), to.Format("2006-01-02"))
		if _, err := s.pool.Exec(ctx, q); err != nil {
			errs = append(errs, fmt.Errorf("%s: %w", name, err))
		}
	}
	return errors.Join(errs...)
}

// withTx runs fn in a transaction, committing if it returns nil. Serialization failures and deadlocks are retried.
func (s *Store) withTx(ctx context.Context, fn func(tx pgx.Tx) error) error {
	var err error
	for attempt := 0; attempt < 4; attempt++ {
		err = s.once(ctx, fn)
		var pe *pgconn.PgError
		if errors.As(err, &pe) && (pe.Code == "40001" || pe.Code == "40P01") {
			continue
		}
		return err
	}
	return err
}

func (s *Store) once(ctx context.Context, fn func(tx pgx.Tx) error) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	if err := fn(tx); err != nil {
		_ = tx.Rollback(ctx)
		return err
	}
	return tx.Commit(ctx)
}

// IsUniqueViolation reports a PostgreSQL unique violation.
func IsUniqueViolation(err error) bool {
	var pe *pgconn.PgError
	return errors.As(err, &pe) && pe.Code == "23505"
}

// --- tokens and keys ---

// NewToken returns a random token (256 bits, URL-safe) and its stored hash.
func NewToken() (token string, hash []byte) {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err) // the system's random source failing is not recoverable
	}
	token = base64.RawURLEncoding.EncodeToString(b[:])
	return token, HashToken(token)
}

// HashToken is what is stored for a token: only its hash, so a database copy gives no session.
func HashToken(token string) []byte {
	h := sha256.Sum256([]byte("fuel-rivals/token/v1\x00" + token))
	return h[:]
}

// ServerKey derives the key of a game server: HMAC-SHA256(master, "fuel-rivals/server-key/v1\0" || server_id || be32(version)).
// The server id is the decimal text of the database id.
func ServerKey(master []byte, serverID int64, version int) []byte {
	m := hmac.New(sha256.New, master)
	m.Write([]byte("fuel-rivals/server-key/v1\x00"))
	m.Write([]byte(strconv.FormatInt(serverID, 10)))
	m.Write(binary.BigEndian.AppendUint32(nil, uint32(version)))
	return m.Sum(nil)
}

// ServerKeyHex is ServerKey as the 64 hex characters handed to the operator.
func ServerKeyHex(master []byte, serverID int64, version int) string {
	return hex.EncodeToString(ServerKey(master, serverID, version))
}

func (s *Store) banHash(steamID string) []byte {
	m := hmac.New(sha256.New, s.cfg.BanSalt)
	m.Write([]byte("fuel-rivals/ban/v1\x00" + steamID))
	return m.Sum(nil)
}

// Audit writes an audit row outside any transaction.
func (s *Store) Audit(ctx context.Context, kind, severity, actor string, matchID, playerID *int64, detail any) {
	_, _ = s.pool.Exec(ctx, `INSERT INTO audit (kind, severity, actor, match_id, player_id, detail)
		VALUES ($1, $2, $3, $4, $5, $6)`, kind, severity, actor, matchID, playerID, jsonOrEmpty(detail))
}

func auditTx(ctx context.Context, tx pgx.Tx, kind, severity, actor string, matchID, playerID *int64, detail any) error {
	_, err := tx.Exec(ctx, `INSERT INTO audit (kind, severity, actor, match_id, player_id, detail)
		VALUES ($1, $2, $3, $4, $5, $6)`, kind, severity, actor, matchID, playerID, jsonOrEmpty(detail))
	return err
}
