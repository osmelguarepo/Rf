package api

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"time"

	"fuelrivals/backend/internal/names"
	"fuelrivals/backend/internal/steam"
	"fuelrivals/backend/internal/store"
)

func itoa(n int) string      { return strconv.Itoa(n) }
func itoa64(n int64) string  { return strconv.FormatInt(n, 10) }

type sessionResponse struct {
	Token     string        `json:"token"`
	ExpiresAt time.Time     `json:"expires_at"`
	Profile   store.Profile `json:"profile"`
}

func (s *Server) newSession(w http.ResponseWriter, r *http.Request, p store.Player, kind string, ttl time.Duration) {
	token, exp, err := s.store.CreateSession(r.Context(), p.ID, kind, ttl)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	prof, err := s.store.ProfileOf(r.Context(), p)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	writeJSON(w, 200, sessionResponse{Token: token, ExpiresAt: exp.UTC(), Profile: prof})
}

// displayName asks Steam for the persona name on the server side (the client's word is not trusted) and derives the
// shown name. If Steam cannot be asked the fallback name is used and the next login fixes it.
func (s *Server) displayName(ctx context.Context, steamID string) string {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	persona, err := s.persona.PersonaName(ctx, steamID)
	if err != nil {
		s.log.Warn("persona name unavailable", "err", err.Error())
		return names.Fallback(steamID)
	}
	return names.Display(persona, steamID)
}

// login completes a verified Steam login: the account, the name and the ban checks.
func (s *Server) login(ctx context.Context, steamID string) (store.Player, error) {
	if ok, _ := s.loginAcct.Allow(steamID); !ok {
		return store.Player{}, errLoginRate
	}
	return s.store.UpsertSteamPlayer(ctx, steamID, s.displayName(ctx, steamID))
}

var errLoginRate = errors.New("too many logins for this account")

// POST /auth/steam {"ticket": "<hex>"}: the desktop client's Steam auth ticket.
func (s *Server) handleAuthSteam(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Ticket string `json:"ticket"`
	}
	if !decode(w, r, 16<<10, &req) {
		return
	}
	v, err := s.verifier.VerifyTicket(r.Context(), req.Ticket)
	switch {
	case errors.Is(err, steam.ErrInvalidTicket):
		writeError(w, 401, "invalid_ticket", "Steam rejected the ticket")
		return
	case err != nil:
		s.log.Warn("steam unavailable", "err", err.Error())
		writeError(w, 503, "steam_unavailable", "could not verify with Steam, try again")
		return
	}
	if v.PublisherBanned {
		writeError(w, 403, "banned", "this Steam account is banned from the game")
		return
	}
	p, err := s.login(r.Context(), v.SteamID)
	if errors.Is(err, errLoginRate) {
		tooMany(w, time.Minute)
		return
	}
	if err != nil {
		s.fail(w, r, err)
		return
	}
	s.newSession(w, r, p, "steam", s.cfg.SessionTTL)
}

// GET /auth/openid/start: the browser goes to Steam. The state is in the return URL and in a __Host- cookie.
func (s *Server) handleOpenIDStart(w http.ResponseWriter, r *http.Request) {
	state, err := s.openid.NewState()
	if err != nil {
		s.fail(w, r, err)
		return
	}
	http.SetCookie(w, stateCookie(state, 600))
	http.Redirect(w, r, s.openid.StartURL(state), http.StatusFound)
}

func stateCookie(value string, maxAge int) *http.Cookie {
	return &http.Cookie{
		Name: steam.StateCookie, Value: value, Path: "/", Secure: true, HttpOnly: true,
		SameSite: http.SameSiteLaxMode, MaxAge: maxAge,
	}
}

// GET /auth/openid/return: Steam sends the browser back. After every check the page gets a one-time code in the URL
// fragment (never the session, never in the query, so it is not sent to any server or logged).
func (s *Server) handleOpenIDReturn(w http.ResponseWriter, r *http.Request) {
	cookie, _ := r.Cookie(steam.StateCookie)
	value := ""
	if cookie != nil {
		value = cookie.Value
	}
	http.SetCookie(w, stateCookie("", -1)) // the cookie is single use
	steamID, err := s.openid.Verify(r.Context(), r.URL.Query(), value)
	if err != nil {
		code := "failed"
		var oe *steam.OpenIDError
		if errors.As(err, &oe) {
			code = oe.Code
		}
		s.log.Warn("openid login refused", "code", code)
		http.Redirect(w, r, s.cfg.PublicURL+"/#login_error="+code, http.StatusFound)
		return
	}
	p, err := s.login(r.Context(), steamID)
	if err != nil {
		code := "failed"
		switch {
		case errors.Is(err, store.ErrBanned):
			code = "banned"
		case errors.Is(err, errLoginRate):
			code = "rate_limited"
		default:
			s.log.Error("openid login failed", "err", err.Error())
		}
		http.Redirect(w, r, s.cfg.PublicURL+"/#login_error="+code, http.StatusFound)
		return
	}
	code, err := s.store.CreateExchangeCode(r.Context(), p.ID, s.cfg.ExchangeTTL)
	if err != nil {
		s.log.Error("exchange code", "err", err.Error())
		http.Redirect(w, r, s.cfg.PublicURL+"/#login_error=failed", http.StatusFound)
		return
	}
	http.Redirect(w, r, s.cfg.PublicURL+"/#code="+code, http.StatusFound)
}

// POST /auth/exchange {"code": "..."}: the one-time code from the fragment becomes a session.
func (s *Server) handleExchange(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Code string `json:"code"`
	}
	if !decode(w, r, 1<<10, &req) {
		return
	}
	if len(req.Code) < 20 || len(req.Code) > 128 {
		writeError(w, 400, "bad_request", "invalid code")
		return
	}
	p, err := s.store.RedeemExchangeCode(r.Context(), req.Code)
	if errors.Is(err, store.ErrNotFound) || errors.Is(err, store.ErrExpired) {
		writeError(w, 401, "invalid_code", "the code is wrong, used or expired")
		return
	}
	if err != nil {
		s.fail(w, r, err)
		return
	}
	s.newSession(w, r, p, "steam", s.cfg.SessionTTL)
}

// POST /auth/guest: an unranked guest for the web, valid 7 days.
func (s *Server) handleGuest(w http.ResponseWriter, r *http.Request) {
	p, err := s.store.CreateGuest(r.Context(), s.now().Add(s.cfg.GuestTTL))
	if err != nil {
		s.fail(w, r, err)
		return
	}
	s.newSession(w, r, p, "guest", s.cfg.GuestTTL)
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request, p store.Player) {
	if err := s.store.DeleteSession(r.Context(), bearer(r)); err != nil {
		s.fail(w, r, err)
		return
	}
	writeJSON(w, 200, map[string]bool{"ok": true})
}
