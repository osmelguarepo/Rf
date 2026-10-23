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
		def  int
		dst  *int
	}{
		{"RATE_LOGIN_PER_MIN", 20, &c.LoginRatePerMin},
		{"RATE_GUEST_PER_HOUR", 10, &c.GuestRatePerHour},
		{"RATE_ACCOUNT_PER_MIN", 120, &c.AccountRatePerMin},
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
