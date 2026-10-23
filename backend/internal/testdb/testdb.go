// Package testdb gives tests a fresh, migrated PostgreSQL database. It needs TEST_DATABASE_URL, the URL of any database
// of a server where the user may create databases (see backend/README.md); without it, or if the server does not answer,
// the test is skipped with a message.
package testdb

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"net/url"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"fuelrivals/backend/internal/store"
)

// Secrets used by the tests.
var (
	MasterKey = []byte("0123456789abcdef0123456789abcdef-master")
	BanSalt   = []byte("test-ban-salt-0123456789")
)

// New returns a store on a new database, dropped when the test ends.
func New(t *testing.T) *store.Store {
	t.Helper()
	base := os.Getenv("TEST_DATABASE_URL")
	if base == "" {
		t.Skip("TEST_DATABASE_URL is not set: skipping the PostgreSQL tests (see backend/README.md to run a temporary server)")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	admin, err := pgxpool.New(ctx, base)
	if err == nil {
		err = admin.Ping(ctx)
	}
	if err != nil {
		t.Skipf("PostgreSQL at TEST_DATABASE_URL does not answer (%v): skipping the PostgreSQL tests", err)
	}
	var b [6]byte
	_, _ = rand.Read(b[:])
	name := "fr_test_" + hex.EncodeToString(b[:])
	if _, err := admin.Exec(ctx, "CREATE DATABASE "+name); err != nil {
		admin.Close()
		t.Fatalf("create database: %v", err)
	}
	u, err := url.Parse(base)
	if err != nil {
		t.Fatal(err)
	}
	u.Path = "/" + name
	pool, err := pgxpool.New(ctx, u.String())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		pool.Close()
		c, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		if _, err := admin.Exec(c, fmt.Sprintf("DROP DATABASE IF EXISTS %s WITH (FORCE)", name)); err != nil {
			t.Logf("drop database %s: %v", name, err)
		}
		admin.Close()
	})
	s := store.New(pool, store.Config{MasterKey: MasterKey, BanSalt: BanSalt})
	if err := s.Migrate(ctx); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	return s
}
