// Package api is the HTTP layer: routing, authentication, rate limits and the handlers.
package api

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"runtime/debug"
	"strings"
	"time"

	"fuelrivals/backend/internal/config"
	"fuelrivals/backend/internal/matchmaker"
	"fuelrivals/backend/internal/steam"
	"fuelrivals/backend/internal/store"
	"fuelrivals/backend/internal/telemetry"
)

// Deps is everything the server needs from outside, so tests can replace Steam and the clock.
type Deps struct {
	Config   config.Config
	Store    *store.Store
	Verifier steam.Verifier
	Persona  steam.Persona
	// SteamHTTP is the client used for the OpenID check_authentication POST (nil: the default client).
	SteamHTTP steam.Doer
	Log       *slog.Logger
	Now       func() time.Time
	// Metrics collects the counters of GET /metrics (nil: a new registry).
	Metrics *telemetry.Registry
}

// Server is the API.
type Server struct {
	cfg      config.Config
	store    *store.Store
	verifier steam.Verifier
	persona  steam.Persona
	openid   *steam.OpenID
	log      *slog.Logger
	now      func() time.Time

	loginIP   *keyedLimiter // /auth/* per IP
	guestIP   *keyedLimiter // guests created per IP
	publicIP  *keyedLimiter // public reads per IP
	accountRL *keyedLimiter // authenticated endpoints per account
	loginAcct *keyedLimiter // logins per SteamID
	queueRL   *keyedLimiter // POST/DELETE /queue, /queue/ready per account
	statusRL  *keyedLimiter // GET /queue/status per account

	metrics *telemetry.Registry
	mm      *matchmaker.Engine
}

// Matchmaker is the live queue (tests drive it with Tick; main runs it with RunMatchmaker).
func (s *Server) Matchmaker() *matchmaker.Engine { return s.mm }

// Metrics is the registry behind GET /metrics.
func (s *Server) Metrics() *telemetry.Registry { return s.metrics }

// New builds the server.
func New(d Deps) *Server {
	now := d.Now
	if now == nil {
		now = time.Now
	}
	log := d.Log
	if log == nil {
		log = slog.New(slog.NewJSONHandler(io.Discard, nil))
	}
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		panic(err)
	}
	// The state secret is per process: a login started before a restart simply has to be started again.
	s := &Server{
		cfg: d.Config, store: d.Store, verifier: d.Verifier, persona: d.Persona, log: log, now: now,
		loginIP:   newKeyedLimiter(d.Config.LoginRatePerMin, time.Minute, d.Config.LoginRatePerMin, now),
		guestIP:   newKeyedLimiter(d.Config.GuestRatePerHour, time.Hour, d.Config.GuestRatePerHour, now),
		publicIP:  newKeyedLimiter(120, time.Minute, 60, now),
		accountRL: newKeyedLimiter(d.Config.AccountRatePerMin, time.Minute, d.Config.AccountRatePerMin, now),
		loginAcct: newKeyedLimiter(d.Config.LoginRatePerMin, time.Minute, 5, now),
		queueRL:   newKeyedLimiter(d.Config.QueueRatePerMin, time.Minute, max(d.Config.QueueRatePerMin/2, 3), now),
		statusRL:  newKeyedLimiter(d.Config.StatusRatePerMin, time.Minute, max(d.Config.StatusRatePerMin/3, 5), now),
		metrics:   d.Metrics,
	}
	if s.metrics == nil {
		s.metrics = telemetry.New()
	}
	s.mm = matchmaker.NewEngine(matchmaker.Params{
		MaxWait: d.Config.QueueMaxWait, SoloWait: d.Config.QueueSoloWait, BandStep: d.Config.QueueBandStep,
		ReadyWindow: d.Config.ReadySeconds, MaxPingMS: d.Config.MaxPingMS,
		PenaltyFree: d.Config.PenaltyFree, PenaltyBase: d.Config.PenaltyBase, PenaltyMax: d.Config.PenaltyMax,
		PenaltyWindow: 24 * time.Hour,
	}, d.Store, now, log, s.metrics)
	s.openid = &steam.OpenID{
		ReturnURL:   d.Config.PublicURL + d.Config.APIPrefix + "/auth/openid/return",
		Realm:       d.Config.PublicURL,
		StateSecret: secret,
		HTTP:        d.SteamHTTP,
		Nonces:      d.Store,
		Now:         now,
	}
	return s
}

// Handler returns the routes wrapped in the middleware.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, 200, map[string]string{"status": "ok"}) })
	mux.HandleFunc("GET /readyz", s.handleReady)

	mux.HandleFunc("POST /auth/steam", s.limitIP(s.loginIP, s.handleAuthSteam))
	mux.HandleFunc("GET /auth/openid/start", s.limitIP(s.loginIP, s.handleOpenIDStart))
	mux.HandleFunc("GET /auth/openid/return", s.limitIP(s.loginIP, s.handleOpenIDReturn))
	mux.HandleFunc("POST /auth/exchange", s.limitIP(s.loginIP, s.handleExchange))
	mux.HandleFunc("POST /auth/guest", s.limitIP(s.guestIP, s.handleGuest))
	mux.HandleFunc("POST /auth/logout", s.auth(s.handleLogout))

	mux.HandleFunc("GET /me", s.auth(s.handleMe))
	mux.HandleFunc("POST /account/delete", s.auth(s.handleDeleteAccount))
	mux.HandleFunc("GET /account/export", s.auth(s.handleExport))
	mux.HandleFunc("POST /reports", s.auth(s.handleReport))
	mux.HandleFunc("GET /leaderboard", s.limitIP(s.publicIP, s.handleLeaderboard))

	mux.HandleFunc("POST /servers/register", s.handleServerRegister)
	mux.HandleFunc("POST /servers/heartbeat", s.serverAuth(s.handleHeartbeat))
	mux.HandleFunc("POST /matches/{id}/result", s.serverAuth(s.handleResult))
	mux.HandleFunc("POST /matches/{id}/replay", s.serverAuth(s.handleReplayUpload))

	mux.HandleFunc("POST /queue", s.auth(s.handleQueueEnter))
	mux.HandleFunc("GET /queue/status", s.auth(s.handleQueueStatus))
	mux.HandleFunc("POST /queue/ready", s.auth(s.handleQueueReady))
	mux.HandleFunc("DELETE /queue", s.auth(s.handleQueueLeave))
	mux.HandleFunc("GET /match/{id}/join", s.auth(s.handleMatchJoin))
	mux.HandleFunc("POST /match/{id}/leave", s.auth(s.handleMatchLeave))

	mux.HandleFunc("GET /metrics", s.handleMetrics)

	mux.HandleFunc("POST /admin/matches", s.admin(s.handleAdminAssign))
	mux.HandleFunc("GET /admin/matches", s.admin(s.handleAdminMatches))
	mux.HandleFunc("GET /admin/matches/{id}", s.admin(s.handleAdminMatch))
	mux.HandleFunc("POST /admin/matches/{id}/annul", s.admin(s.handleAdminAnnul))
	mux.HandleFunc("GET /admin/matches/{id}/replay", s.admin(s.handleAdminReplay))
	mux.HandleFunc("POST /admin/players/{id}/ban", s.admin(s.handleAdminBan))
	mux.HandleFunc("POST /admin/players/{id}/unban", s.admin(s.handleAdminUnban))
	mux.HandleFunc("GET /admin/servers", s.admin(s.handleAdminServers))
	mux.HandleFunc("POST /admin/servers/{id}/drain", s.admin(s.handleAdminDrain))
	mux.HandleFunc("GET /admin/queue", s.admin(s.handleAdminQueue))

	return s.recoverer(s.logRequests(s.secureHeaders(mux)))
}

// --- middleware ---

type ctxKey int

const keyPlayer ctxKey = iota

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(code int) {
	w.status = code
	w.ResponseWriter.WriteHeader(code)
}

func (s *Server) recoverer(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if v := recover(); v != nil {
				s.log.Error("panic", "panic", v, "stack", string(debug.Stack()), "path", r.URL.Path)
				writeError(w, 500, "internal", "internal error")
			}
		}()
		next.ServeHTTP(w, r)
	})
}

// logRequests writes one JSON line per request. The path is logged without the query (state, codes) and no IP address
// is logged: the address is only used in memory for rate limits.
func (s *Server) logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := s.now()
		sw := &statusWriter{ResponseWriter: w, status: 200}
		next.ServeHTTP(sw, r)
		s.log.Info("request", "method", r.Method, "path", r.URL.Path, "status", sw.status, "ms", s.now().Sub(start).Milliseconds())
		route := r.Pattern // "GET /queue/status"; empty when nothing matched (kept out of the labels: unbounded)
		if route == "" {
			route = "unmatched"
		}
		s.metrics.Inc("fr_http_requests_total", "HTTP requests by route and status.", "route", route, "status", itoa(sw.status))
	})
}

func (s *Server) secureHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Cache-Control", "no-store")
		next.ServeHTTP(w, r)
	})
}

// clientIP is the address of the caller: the last X-Forwarded-For entry (added by our own proxy) when TRUST_PROXY is
// on, otherwise the socket's address.
func (s *Server) clientIP(r *http.Request) string {
	if s.cfg.TrustProxy {
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			parts := strings.Split(xff, ",")
			if ip := strings.TrimSpace(parts[len(parts)-1]); net.ParseIP(ip) != nil {
				return ip
			}
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func (s *Server) limitIP(l *keyedLimiter, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if ok, wait := l.Allow(s.clientIP(r)); !ok {
			tooMany(w, wait)
			return
		}
		next(w, r)
	}
}

func tooMany(w http.ResponseWriter, wait time.Duration) {
	secs := int(wait.Seconds()) + 1
	w.Header().Set("Retry-After", itoa(secs))
	writeError(w, http.StatusTooManyRequests, "rate_limited", "too many requests, try again later")
}

type playerHandler func(w http.ResponseWriter, r *http.Request, p store.Player)

// auth requires a session token and applies the per-account rate limit.
func (s *Server) auth(next playerHandler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := bearer(r)
		if token == "" {
			writeError(w, 401, "unauthorized", "missing session token")
			return
		}
		p, err := s.store.PlayerBySession(r.Context(), token)
		if err != nil {
			if errors.Is(err, store.ErrNotFound) {
				writeError(w, 401, "unauthorized", "invalid or expired session")
				return
			}
			s.fail(w, r, err)
			return
		}
		if ok, wait := s.accountRL.Allow(itoa64(p.ID)); !ok {
			tooMany(w, wait)
			return
		}
		next(w, r, p)
	}
}

type serverHandler func(w http.ResponseWriter, r *http.Request, sv store.Server)

// serverAuth requires X-Server-Id and the server's key as Bearer token.
func (s *Server) serverAuth(next serverHandler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sv, err := s.store.AuthServer(r.Context(), r.Header.Get("X-Server-Id"), bearer(r))
		if err != nil {
			if errors.Is(err, store.ErrForbidden) {
				writeError(w, 401, "unauthorized", "bad server id or key")
				return
			}
			s.fail(w, r, err)
			return
		}
		next(w, r, sv)
	}
}

func (s *Server) admin(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !tokenEquals(bearer(r), s.cfg.AdminToken) {
			writeError(w, 401, "unauthorized", "admin token required")
			return
		}
		next(w, r)
	}
}

func tokenEquals(got, want string) bool {
	if got == "" || want == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(got), []byte(want)) == 1
}

func bearer(r *http.Request) string {
	h := r.Header.Get("Authorization")
	if len(h) > 7 && strings.EqualFold(h[:7], "bearer ") {
		return strings.TrimSpace(h[7:])
	}
	return ""
}

// --- responses ---

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, code, msg string) {
	writeJSON(w, status, map[string]string{"error": code, "message": msg})
}

// decode reads a JSON body of at most max bytes, refusing unknown fields and trailing data.
func decode(w http.ResponseWriter, r *http.Request, max int64, v any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, max)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			writeError(w, http.StatusRequestEntityTooLarge, "too_large", "body too large")
		} else {
			writeError(w, 400, "bad_request", "invalid JSON body")
		}
		return false
	}
	if dec.More() {
		writeError(w, 400, "bad_request", "unexpected data after the JSON body")
		return false
	}
	return true
}

// fail answers a store error with the matching status. Anything unexpected is logged and reported as 500 without detail.
func (s *Server) fail(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeError(w, 404, "not_found", "not found")
	case errors.Is(err, store.ErrBadRequest):
		writeError(w, 400, "bad_request", err.Error())
	case errors.Is(err, store.ErrForbidden):
		writeError(w, 403, "forbidden", "not allowed")
	case errors.Is(err, store.ErrBanned):
		writeError(w, 403, "banned", "this account is banned")
	case errors.Is(err, store.ErrConflict):
		writeError(w, 409, "conflict", "a different result was already settled for this match")
	case errors.Is(err, store.ErrBusy):
		writeError(w, 409, "busy", "a match is in progress")
	case errors.Is(err, store.ErrGone):
		writeError(w, 410, "gone", "the match is void or annulled")
	case errors.Is(err, store.ErrDraining):
		writeError(w, 503, "unavailable", "the server is not accepting matches")
	case errors.Is(err, context.Canceled):
		writeError(w, 499, "canceled", "request canceled")
	default:
		s.log.Error("request failed", "path", r.URL.Path, "err", err.Error())
		writeError(w, 500, "internal", "internal error")
	}
}

func (s *Server) handleReady(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if err := s.store.Ping(ctx); err != nil {
		writeError(w, 503, "not_ready", "database unreachable")
		return
	}
	writeJSON(w, 200, map[string]string{"status": "ready"})
}

// RandomHex is n random bytes as hex (used by tools and tests).
func RandomHex(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
