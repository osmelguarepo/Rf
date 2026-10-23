// Package config reads the service configuration from environment variables.
package config

import (
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

// Config is everything the API needs to run. Secrets come only from the environment.
type Config struct {
	ListenAddr  string // LISTEN_ADDR, default ":8080"
	DatabaseURL string // DATABASE_URL (required)
	PublicURL   string // PUBLIC_URL, the origin players see, e.g. https://play.example.com (no trailing slash)
	APIPrefix   string // API_PREFIX, where the reverse proxy mounts the API, default "/api"
	TrustProxy  bool   // TRUST_PROXY: take the client address from X-Forwarded-For (only behind Caddy)
	LogLevel    string // LOG_LEVEL: debug, info, warn, error

	SteamWebAPIKey      string // STEAM_WEB_API_KEY: GetPlayerSummaries (the persona name)
	SteamPartnerKey     string // STEAM_PARTNER_API_KEY: ISteamUserAuth/AuthenticateUserTicket (publisher key)
	SteamAppID          string // STEAM_APP_ID
	SteamTicketIdentity string // STEAM_TICKET_IDENTITY, default "fuelrivals"

	MasterKey           []byte // MASTER_KEY: 32 or more bytes as hex; game server keys are derived from it
	BanSalt             []byte // BAN_SALT: hex or text; salts the hashes kept for bans
	AdminToken          string // ADMIN_TOKEN: bearer token of the admin endpoints (min 24 chars)
	ServerRegisterToken string // SERVER_REGISTER_TOKEN: bearer token that allows registering game servers

	SessionTTL     time.Duration // SESSION_TTL, default 24h
	GuestTTL       time.Duration // GUEST_TTL, default 7 days
	ExchangeTTL    time.Duration // fixed 60 s (SPEC_ONLINE 16.3)
	LeaseTTL       time.Duration // LEASE_TTL: how long a heartbeat keeps a game server alive, default 30s
	VoidAfter      time.Duration // VOID_AFTER: unsettled matches of a silent server are voided after this, default 6h
	ReplayMaxBytes int64         // REPLAY_MAX_BYTES, default 256 KiB

	LoginRatePerMin   int // RATE_LOGIN_PER_MIN: per IP on /auth/* (default 20)
	GuestRatePerHour  int // RATE_GUEST_PER_HOUR: guests created per IP (default 10)
	AccountRatePerMin int // RATE_ACCOUNT_PER_MIN: per account on authenticated endpoints (default 120)
	QueueRatePerMin   int // RATE_QUEUE_PER_MIN: POST/DELETE /queue and /queue/ready per account (default 20)
	StatusRatePerMin  int // RATE_STATUS_PER_MIN: GET /queue/status per account (default 90; clients poll about once a second)

	// Matchmaking (docs/MATCHMAKING.md).
	QueueMaxWait      time.Duration // QUEUE_MAX_WAIT: a group of 2 or more launches when its oldest ticket waited this long (30s)
	QueueSoloWait     time.Duration // QUEUE_SOLO_WAIT: a lone human gets a bot-filled race after this (30s)
	QueueBandStep     time.Duration // QUEUE_BAND_STEP: the compatibility band grows one division per step (10s)
	ReadySeconds      time.Duration // READY_SECONDS: time to confirm a found match (15s)
	MaxPingMS         int           // MAX_PING_MS: above this a group waits QUEUE_MAX_WAIT before accepting the server (250)
	MatchmakerTick    time.Duration // MATCHMAKER_TICK: how often the matching loop runs (1s)
	PenaltyFree       int           // PENALTY_FREE_STRIKES: strikes per day that do not ban (2)
	PenaltyBase       time.Duration // PENALTY_BASE: the first queue ban, doubled with each further strike (5m)
	PenaltyMax        time.Duration // PENALTY_MAX: the longest queue ban (2h)
	MetricsToken      string        // METRICS_TOKEN: bearer token of GET /metrics; without it /metrics answers 404
	DisableMatchmaker bool          // MATCHMAKER=off: no matching loop (tests that drive POST /admin/matches only)
}

// FromEnv builds the configuration from os.Getenv and validates it.
func FromEnv() (Config, error) { return FromLookup(os.Getenv) }

// FromLookup is FromEnv with an injectable lookup, for tests.
func FromLookup(get func(string) string) (Config, error) {
	c := Config{
		ListenAddr:          def(get("LISTEN_ADDR"), ":8080"),
		DatabaseURL:         get("DATABASE_URL"),
		PublicURL:           strings.TrimRight(get("PUBLIC_URL"), "/"),
		APIPrefix:           def(get("API_PREFIX"), "/api"),
		TrustProxy:          get("TRUST_PROXY") == "true" || get("TRUST_PROXY") == "1",
		LogLevel:            def(get("LOG_LEVEL"), "info"),
		SteamWebAPIKey:      get("STEAM_WEB_API_KEY"),
		SteamPartnerKey:     get("STEAM_PARTNER_API_KEY"),
		SteamAppID:          get("STEAM_APP_ID"),
		SteamTicketIdentity: def(get("STEAM_TICKET_IDENTITY"), "fuelrivals"),
		AdminToken:          get("ADMIN_TOKEN"),
		ServerRegisterToken: get("SERVER_REGISTER_TOKEN"),
		ExchangeTTL:         60 * time.Second,
	}
	var errs []error
	if c.DatabaseURL == "" {
		errs = append(errs, errors.New("DATABASE_URL is required"))
	}
	if !strings.HasPrefix(c.PublicURL, "https://") && !strings.HasPrefix(c.PublicURL, "http://localhost") &&
		!strings.HasPrefix(c.PublicURL, "http://127.0.0.1") {
		errs = append(errs, errors.New("PUBLIC_URL must be an https:// origin (http only for localhost)"))
	}
	if c.APIPrefix != "" && (!strings.HasPrefix(c.APIPrefix, "/") || strings.HasSuffix(c.APIPrefix, "/")) {
		errs = append(errs, errors.New("API_PREFIX must start with / and not end with /, or be empty"))
	}
	if key, err := hex.DecodeString(get("MASTER_KEY")); err != nil || len(key) < 32 {
		errs = append(errs, errors.New("MASTER_KEY must be at least 32 bytes as hex (openssl rand -hex 32)"))
	} else {
		c.MasterKey = key
	}
	if salt := get("BAN_SALT"); len(salt) < 16 {
		errs = append(errs, errors.New("BAN_SALT must be at least 16 characters"))
	} else {
		c.BanSalt = []byte(salt)
	}
	if len(c.AdminToken) < 24 {
		errs = append(errs, errors.New("ADMIN_TOKEN must be at least 24 characters"))
	}
	if len(c.ServerRegisterToken) < 24 {
		errs = append(errs, errors.New("SERVER_REGISTER_TOKEN must be at least 24 characters"))
	}
	var err error
	if c.SessionTTL, err = dur(get, "SESSION_TTL", 24*time.Hour); err != nil {
		errs = append(errs, err)
	}
	if c.GuestTTL, err = dur(get, "GUEST_TTL", 7*24*time.Hour); err != nil {
		errs = append(errs, err)
	}
	if c.LeaseTTL, err = dur(get, "LEASE_TTL", 30*time.Second); err != nil {
		errs = append(errs, err)
	}
	if c.VoidAfter, err = dur(get, "VOID_AFTER", 6*time.Hour); err != nil {
		errs = append(errs, err)
	}
	for _, v := range []struct {
		name string
		def  time.Duration
		dst  *time.Duration
	}{
		{"QUEUE_MAX_WAIT", 30 * time.Second, &c.QueueMaxWait},
		{"QUEUE_SOLO_WAIT", 30 * time.Second, &c.QueueSoloWait},
		{"QUEUE_BAND_STEP", 10 * time.Second, &c.QueueBandStep},
		{"READY_SECONDS", 15 * time.Second, &c.ReadySeconds},
		{"MATCHMAKER_TICK", time.Second, &c.MatchmakerTick},
		{"PENALTY_BASE", 5 * time.Minute, &c.PenaltyBase},
		{"PENALTY_MAX", 2 * time.Hour, &c.PenaltyMax},
	} {
		d, err := dur(get, v.name, v.def)
		if err != nil {
			errs = append(errs, err)
		}
		*v.dst = d
	}
	c.MetricsToken = get("METRICS_TOKEN")
	if c.MetricsToken != "" && len(c.MetricsToken) < 16 {
		errs = append(errs, errors.New("METRICS_TOKEN must be at least 16 characters"))
	}
	c.DisableMatchmaker = get("MATCHMAKER") == "off"
	for _, v := range []struct {
		name string
		def  int
		dst  *int
	}{
		{"RATE_LOGIN_PER_MIN", 20, &c.LoginRatePerMin},
		{"RATE_GUEST_PER_HOUR", 10, &c.GuestRatePerHour},
		{"RATE_ACCOUNT_PER_MIN", 120, &c.AccountRatePerMin},
		{"RATE_QUEUE_PER_MIN", 20, &c.QueueRatePerMin},
		{"RATE_STATUS_PER_MIN", 90, &c.StatusRatePerMin},
		{"MAX_PING_MS", 250, &c.MaxPingMS},
		{"PENALTY_FREE_STRIKES", 2, &c.PenaltyFree},
	} {
		n, err := integer(get, v.name, v.def)
		if err != nil {
			errs = append(errs, err)
		}
		*v.dst = n
	}
	n, err := integer(get, "REPLAY_MAX_BYTES", 256*1024)
	if err != nil {
		errs = append(errs, err)
	}
	c.ReplayMaxBytes = int64(n)
	return c, errors.Join(errs...)
}

func def(v, d string) string {
	if v == "" {
		return d
	}
	return v
}

func dur(get func(string) string, name string, d time.Duration) (time.Duration, error) {
	v := get(name)
	if v == "" {
		return d, nil
	}
	x, err := time.ParseDuration(v)
	if n, aerr := strconv.Atoi(v); aerr == nil { // a plain number is seconds: READY_SECONDS=15
		x, err = time.Duration(n)*time.Second, nil
	}
	if err != nil || x <= 0 {
		return d, fmt.Errorf("%s: not a positive duration: %q", name, v)
	}
	return x, nil
}

func integer(get func(string) string, name string, d int) (int, error) {
	v := get(name)
	if v == "" {
		return d, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil || n <= 0 {
		return d, fmt.Errorf("%s: not a positive integer: %q", name, v)
	}
	return n, nil
}
