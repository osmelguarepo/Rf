package api_test

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"fuelrivals/backend/internal/api"
	"fuelrivals/backend/internal/config"
	"fuelrivals/backend/internal/steam"
	"fuelrivals/backend/internal/store"
	"fuelrivals/backend/internal/testdb"
	"fuelrivals/backend/internal/ticket"
)

const (
	adminToken    = "admin-token-0123456789abcdef-xyz"
	registerToken = "register-token-0123456789abcdef"
	publicURL     = "https://play.example.com"
)

// steamDouble plays steamcommunity.com for the OpenID check_authentication POST.
type steamDouble struct {
	mu       sync.Mutex
	valid    bool
	requests []string
}

func (d *steamDouble) Do(r *http.Request) (*http.Response, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.requests = append(d.requests, r.Method+" "+r.URL.String())
	body := "is_valid:false\n"
	if d.valid {
		body = "ns:http://specs.openid.net/auth/2.0\nis_valid:true\n"
	}
	return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body))}, nil
}

type env struct {
	t       *testing.T
	ts      *httptest.Server
	st      *store.Store
	now     time.Time
	persona *steam.FakePersona
	steam   *steamDouble
	cfg     config.Config
}

func newEnv(t *testing.T, tweak func(m map[string]string)) *env {
	t.Helper()
	e := &env{t: t, now: time.Date(2026, 10, 23, 12, 0, 0, 0, time.UTC), steam: &steamDouble{valid: true}}
	e.st = testdb.New(t)
	e.st.Now = func() time.Time { return e.now }
	m := map[string]string{
		"DATABASE_URL": "postgres://unused", "PUBLIC_URL": publicURL,
		"MASTER_KEY": hex.EncodeToString(testdb.MasterKey), "BAN_SALT": string(testdb.BanSalt),
		"ADMIN_TOKEN": adminToken, "SERVER_REGISTER_TOKEN": registerToken,
		"RATE_LOGIN_PER_MIN": "1000", "RATE_GUEST_PER_HOUR": "1000", "RATE_ACCOUNT_PER_MIN": "1000",
	}
	if tweak != nil {
		tweak(m)
	}
	cfg, err := config.FromLookup(func(k string) string { return m[k] })
	if err != nil {
		t.Fatal(err)
	}
	e.cfg = cfg
	e.persona = &steam.FakePersona{Names: map[string]string{}}
	srv := api.New(api.Deps{Config: cfg, Store: e.st, Verifier: steam.FakeVerifier{}, Persona: e.persona,
		SteamHTTP: e.steam, Now: func() time.Time { return e.now }})
	e.ts = httptest.NewServer(srv.Handler())
	t.Cleanup(e.ts.Close)
	return e
}

type resp struct {
	Status int
	Header http.Header
	Body   []byte
}

func (r resp) json(t *testing.T) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(r.Body, &m); err != nil {
		t.Fatalf("not JSON (%d): %s", r.Status, r.Body)
	}
	return m
}

// noRedirect keeps redirects visible.
var client = &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}

func (e *env) do(method, path string, body any, headers map[string]string) resp {
	e.t.Helper()
	var rd io.Reader
	switch b := body.(type) {
	case nil:
	case []byte:
		rd = bytes.NewReader(b)
	case string:
		rd = strings.NewReader(b)
	default:
		raw, _ := json.Marshal(b)
		rd = bytes.NewReader(raw)
	}
	req, err := http.NewRequest(method, e.ts.URL+path, rd)
	if err != nil {
		e.t.Fatal(err)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	res, err := client.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(res.Body)
	return resp{res.StatusCode, res.Header, b}
}

func bearer(tok string) map[string]string { return map[string]string{"Authorization": "Bearer " + tok} }

func (e *env) loginSteam(id string) (token string, profile map[string]any) {
	e.t.Helper()
	r := e.do("POST", "/auth/steam", map[string]string{"ticket": "ok-" + id}, nil)
	if r.Status != 200 {
		e.t.Fatalf("login: %d %s", r.Status, r.Body)
	}
	j := r.json(e.t)
	return j["token"].(string), j["profile"].(map[string]any)
}

func (e *env) registerServer() (id, key string) {
	e.t.Helper()
	r := e.do("POST", "/servers/register", map[string]any{"name": "eu-1", "region": "eu", "url": "wss://eu.example.com", "capacity": 20}, bearer(registerToken))
	if r.Status != 201 {
		e.t.Fatalf("register: %d %s", r.Status, r.Body)
	}
	j := r.json(e.t)
	id, key = j["server_id"].(string), j["key"].(string)
	hb := e.do("POST", "/servers/heartbeat", map[string]any{"capacity": 20, "metrics": map[string]any{"cpu": 0.3}}, serverAuth(id, key))
	if hb.Status != 200 {
		e.t.Fatalf("heartbeat: %d %s", hb.Status, hb.Body)
	}
	return id, key
}

func serverAuth(id, key string) map[string]string {
	return map[string]string{"X-Server-Id": id, "Authorization": "Bearer " + key}
}

const (
	steamA = "76561198000000001"
	steamB = "76561198000000002"
)

func TestSteamLoginAndMe(t *testing.T) {
	e := newEnv(t, nil)
	e.persona.Names[steamA] = "Speedy Racer"
	token, prof := e.loginSteam(steamA)
	if prof["name"] != "SPEEDYRA" || prof["steam_id"] != steamA || prof["guest"] != false || prof["points"].(float64) != 0 {
		t.Errorf("profile %v", prof)
	}
	if _, leaks := prof["strength"]; leaks {
		t.Error("the hidden rating must not be sent to players")
	}
	me := e.do("GET", "/me", nil, bearer(token)).json(t)
	if me["division_name"] != "BRONZE" || me["points_to_next"].(float64) != 300 || me["ranked"] != true {
		t.Errorf("me %v", me)
	}
	// One active session: logging in again ends the first token.
	token2, _ := e.loginSteam(steamA)
	if r := e.do("GET", "/me", nil, bearer(token)); r.Status != 401 {
		t.Errorf("old token: %d", r.Status)
	}
	if r := e.do("GET", "/me", nil, bearer(token2)); r.Status != 200 {
		t.Errorf("new token: %d", r.Status)
	}
	// No token, garbage token.
	if r := e.do("GET", "/me", nil, nil); r.Status != 401 {
		t.Error("no token")
	}
	if r := e.do("GET", "/me", nil, bearer("nope")); r.Status != 401 {
		t.Error("bad token")
	}
	// Logout.
	if r := e.do("POST", "/auth/logout", nil, bearer(token2)); r.Status != 200 {
		t.Error("logout")
	}
	if r := e.do("GET", "/me", nil, bearer(token2)); r.Status != 401 {
		t.Error("after logout")
	}
}

func TestSteamLoginFailures(t *testing.T) {
	e := newEnv(t, nil)
	cases := []struct {
		name   string
		body   any
		status int
	}{
		{"invalid ticket", map[string]string{"ticket": "garbage"}, 401},
		{"steam down", map[string]string{"ticket": "down"}, 503},
		{"publisher banned", map[string]string{"ticket": "banned-" + steamA}, 403},
		{"not json", "{{", 400},
		{"unknown field", map[string]string{"ticket": "ok-" + steamA, "steam_id": "1"}, 400},
		{"trailing data", `{"ticket":"x"} {"a":1}`, 400},
		{"too large", `{"ticket":"` + strings.Repeat("a", 20000) + `"}`, 413},
	}
	for _, c := range cases {
		if r := e.do("POST", "/auth/steam", c.body, nil); r.Status != c.status {
			t.Errorf("%s: %d %s", c.name, r.Status, r.Body)
		}
	}
	// Persona unavailable: login still works with the fallback name.
	e.persona.Err = steam.ErrUnavailable
	_, prof := e.loginSteam(steamB)
	if prof["name"] != "P0002" {
		t.Errorf("fallback name %v", prof["name"])
	}
}

func TestBannedAccountCannotLogin(t *testing.T) {
	e := newEnv(t, nil)
	token, prof := e.loginSteam(steamA)
	id := prof["player_id"].(string)
	if r := e.do("POST", "/admin/players/"+id+"/ban", map[string]string{"reason": "test"}, bearer(adminToken)); r.Status != 200 {
		t.Fatalf("ban: %d %s", r.Status, r.Body)
	}
	if r := e.do("GET", "/me", nil, bearer(token)); r.Status != 401 {
		t.Error("banned session still works")
	}
	if r := e.do("POST", "/auth/steam", map[string]string{"ticket": "ok-" + steamA}, nil); r.Status != 403 {
		t.Errorf("banned login: %d", r.Status)
	}
}

func TestGuests(t *testing.T) {
	e := newEnv(t, nil)
	r := e.do("POST", "/auth/guest", nil, nil)
	if r.Status != 200 {
		t.Fatalf("%d %s", r.Status, r.Body)
	}
	j := r.json(t)
	token := j["token"].(string)
	exp, _ := time.Parse(time.RFC3339, j["expires_at"].(string))
	if d := exp.Sub(e.now); d != 7*24*time.Hour {
		t.Errorf("guest lasts %v", d)
	}
	me := e.do("GET", "/me", nil, bearer(token)).json(t)
	if me["guest"] != true || me["ranked"] != false || me["rank"].(float64) != 0 || me["steam_id"] != nil {
		t.Errorf("guest profile %v", me)
	}
	e.now = e.now.Add(7*24*time.Hour + time.Second)
	if r := e.do("GET", "/me", nil, bearer(token)); r.Status != 401 {
		t.Error("expired guest token")
	}
}

func TestRateLimits(t *testing.T) {
	e := newEnv(t, func(m map[string]string) {
		m["RATE_LOGIN_PER_MIN"] = "5"
		m["RATE_GUEST_PER_HOUR"] = "3"
		m["RATE_ACCOUNT_PER_MIN"] = "4"
	})
	// Guests: 3 per hour per IP.
	for i := 0; i < 3; i++ {
		if r := e.do("POST", "/auth/guest", nil, nil); r.Status != 200 {
			t.Fatalf("guest %d: %d", i, r.Status)
		}
	}
	r := e.do("POST", "/auth/guest", nil, nil)
	if r.Status != 429 || r.Header.Get("Retry-After") == "" {
		t.Errorf("4th guest: %d %v", r.Status, r.Header)
	}
	// An hour later the bucket has refilled a little.
	e.now = e.now.Add(21 * time.Minute)
	if r := e.do("POST", "/auth/guest", nil, nil); r.Status != 200 {
		t.Errorf("after refill: %d", r.Status)
	}

	// Login: 5 per minute per IP, including bad tickets.
	for i := 0; i < 5; i++ {
		e.do("POST", "/auth/steam", map[string]string{"ticket": "garbage"}, nil)
	}
	if r := e.do("POST", "/auth/steam", map[string]string{"ticket": "garbage"}, nil); r.Status != 429 {
		t.Errorf("login flood: %d", r.Status)
	}
	if r := e.do("GET", "/auth/openid/start", nil, nil); r.Status != 429 {
		t.Errorf("openid start shares the IP budget: %d", r.Status)
	}
	e.now = e.now.Add(time.Minute)

	// X-Forwarded-For is ignored unless TRUST_PROXY is on: a spoofed address does not get a fresh budget.
	for i := 0; i < 5; i++ {
		e.do("POST", "/auth/steam", map[string]string{"ticket": "garbage"}, map[string]string{"X-Forwarded-For": "9.9.9." + strconv.Itoa(i)})
	}
	if r := e.do("POST", "/auth/steam", map[string]string{"ticket": "garbage"}, map[string]string{"X-Forwarded-For": "1.2.3.4"}); r.Status != 429 {
		t.Errorf("spoofed forwarded header must not reset the limit: %d", r.Status)
	}
	e.now = e.now.Add(time.Minute)

	// Per account: 4 requests per minute on authenticated endpoints.
	token, _ := e.loginSteam(steamA)
	for i := 0; i < 4; i++ {
		if r := e.do("GET", "/me", nil, bearer(token)); r.Status != 200 {
			t.Fatalf("me %d: %d", i, r.Status)
		}
	}
	if r := e.do("GET", "/me", nil, bearer(token)); r.Status != 429 {
		t.Errorf("account flood: %d", r.Status)
	}
	// Another account is not affected.
	e.now = e.now.Add(time.Minute)
	token2, _ := e.loginSteam(steamB)
	if r := e.do("GET", "/me", nil, bearer(token2)); r.Status != 200 {
		t.Errorf("other account: %d", r.Status)
	}
}

func TestPerAccountLoginLimit(t *testing.T) {
	// The IP budget is large; the same SteamID may not churn sessions endlessly (burst 5).
	e := newEnv(t, nil)
	var last int
	for i := 0; i < 8; i++ {
		last = e.do("POST", "/auth/steam", map[string]string{"ticket": "ok-" + steamA}, nil).Status
	}
	if last != 429 {
		t.Errorf("8th login of one account in a burst: %d", last)
	}
}

func TestTrustedProxyUsesTheLastForwardedAddress(t *testing.T) {
	e := newEnv(t, func(m map[string]string) { m["RATE_GUEST_PER_HOUR"] = "1"; m["TRUST_PROXY"] = "true" })
	h := func(ip string) map[string]string { return map[string]string{"X-Forwarded-For": "6.6.6.6, " + ip} }
	if r := e.do("POST", "/auth/guest", nil, h("1.1.1.1")); r.Status != 200 {
		t.Fatal(r.Status)
	}
	if r := e.do("POST", "/auth/guest", nil, h("1.1.1.1")); r.Status != 429 {
		t.Errorf("same client: %d", r.Status)
	}
	if r := e.do("POST", "/auth/guest", nil, h("2.2.2.2")); r.Status != 200 {
		t.Errorf("another client: %d", r.Status)
	}
}

// --- OpenID through HTTP ---

func (e *env) openidStart() (state, cookie string) {
	e.t.Helper()
	r := e.do("GET", "/auth/openid/start", nil, nil)
	if r.Status != 302 {
		e.t.Fatalf("start: %d", r.Status)
	}
	loc, _ := url.Parse(r.Header.Get("Location"))
	if loc.Scheme+"://"+loc.Host+loc.Path != "https://steamcommunity.com/openid/login" {
		e.t.Fatalf("start redirects to %s", loc)
	}
	returnTo, _ := url.Parse(loc.Query().Get("openid.return_to"))
	if returnTo.Scheme+"://"+returnTo.Host+returnTo.Path != publicURL+"/api/auth/openid/return" {
		e.t.Fatalf("return_to %s", returnTo)
	}
	state = returnTo.Query().Get("state")
	setCookie := r.Header.Get("Set-Cookie")
	for _, want := range []string{"__Host-fr_oid=", "Secure", "HttpOnly", "SameSite=Lax", "Path=/"} {
		if !strings.Contains(setCookie, want) {
			e.t.Fatalf("cookie %q lacks %s", setCookie, want)
		}
	}
	if strings.Contains(setCookie, "Domain") {
		e.t.Fatal("a __Host- cookie must not have a Domain")
	}
	return state, "__Host-fr_oid=" + state
}

func (e *env) openidReturn(state, cookie, nonce, steamID string) resp {
	q := url.Values{
		"state":                 {state},
		"openid.ns":             {"http://specs.openid.net/auth/2.0"},
		"openid.mode":           {"id_res"},
		"openid.op_endpoint":    {"https://steamcommunity.com/openid/login"},
		"openid.claimed_id":     {"https://steamcommunity.com/openid/id/" + steamID},
		"openid.identity":       {"https://steamcommunity.com/openid/id/" + steamID},
		"openid.return_to":      {publicURL + "/api/auth/openid/return?state=" + url.QueryEscape(state)},
		"openid.response_nonce": {nonce},
		"openid.assoc_handle":   {"1234"},
		"openid.signed":         {"signed,op_endpoint,claimed_id,identity,return_to,response_nonce,assoc_handle"},
		"openid.sig":            {"c2ln"},
	}
	h := map[string]string{}
	if cookie != "" {
		h["Cookie"] = cookie
	}
	return e.do("GET", "/auth/openid/return?"+q.Encode(), nil, h)
}

func nonceAt(t time.Time, suffix string) string { return t.UTC().Format("2006-01-02T15:04:05Z") + suffix }

func TestOpenIDLoginEndToEnd(t *testing.T) {
	e := newEnv(t, nil)
	e.persona.Names[steamA] = "Web Player"
	state, cookie := e.openidStart()
	r := e.openidReturn(state, cookie, nonceAt(e.now, "n1"), steamA)
	if r.Status != 302 {
		t.Fatalf("return: %d %s", r.Status, r.Body)
	}
	loc := r.Header.Get("Location")
	if !strings.HasPrefix(loc, publicURL+"/#code=") {
		t.Fatalf("redirect %q: the code must be in the fragment, on the page", loc)
	}
	if strings.Contains(loc, "?") {
		t.Fatalf("no query allowed in the redirect: %q", loc)
	}
	if !strings.Contains(r.Header.Get("Set-Cookie"), "Max-Age=0") && !strings.Contains(r.Header.Get("Set-Cookie"), "Max-Age=-") {
		// Go writes a deleted cookie as "Max-Age=0".
		t.Errorf("the state cookie must be cleared: %q", r.Header.Get("Set-Cookie"))
	}
	if r.Header.Get("Referrer-Policy") != "no-referrer" || r.Header.Get("Cache-Control") != "no-store" {
		t.Errorf("headers %v", r.Header)
	}
	code := strings.TrimPrefix(loc, publicURL+"/#code=")
	ex := e.do("POST", "/auth/exchange", map[string]string{"code": code}, nil)
	if ex.Status != 200 {
		t.Fatalf("exchange: %d %s", ex.Status, ex.Body)
	}
	j := ex.json(t)
	if j["profile"].(map[string]any)["name"] != "WEBPLAYE" {
		t.Errorf("profile %v", j["profile"])
	}
	token := j["token"].(string)
	if r := e.do("GET", "/me", nil, bearer(token)); r.Status != 200 {
		t.Errorf("me: %d", r.Status)
	}
	// The code is single use.
	if r := e.do("POST", "/auth/exchange", map[string]string{"code": code}, nil); r.Status != 401 {
		t.Errorf("second exchange: %d", r.Status)
	}
	// The assertion with the same nonce cannot be replayed, even with a fresh state.
	state2, cookie2 := e.openidStart()
	r = e.openidReturn(state2, cookie2, nonceAt(e.now, "n1"), steamA)
	if !strings.Contains(r.Header.Get("Location"), "login_error=nonce_replay") {
		t.Errorf("replayed nonce: %q", r.Header.Get("Location"))
	}
	// Exactly one POST to Steam per accepted assertion, always to the hard-coded URL.
	for _, req := range e.steam.requests {
		if req != "POST https://steamcommunity.com/openid/login" {
			t.Errorf("request to %s", req)
		}
	}
	if len(e.steam.requests) != 1 {
		t.Errorf("%d requests to Steam", len(e.steam.requests))
	}
}

func TestOpenIDRefusals(t *testing.T) {
	e := newEnv(t, nil)
	locationOf := func(r resp) string { return r.Header.Get("Location") }

	state, cookie := e.openidStart()
	if l := locationOf(e.openidReturn(state, "", nonceAt(e.now, "a"), steamA)); !strings.HasSuffix(l, "login_error=cookie") {
		t.Errorf("no cookie: %s", l)
	}
	other, otherCookie := e.openidStart()
	if l := locationOf(e.openidReturn(state, otherCookie, nonceAt(e.now, "b"), steamA)); !strings.HasSuffix(l, "login_error=cookie") {
		t.Errorf("cookie of another login: %s", l)
	}
	_ = other
	if l := locationOf(e.openidReturn("AAAA.1.AAAA", "__Host-fr_oid=AAAA.1.AAAA", nonceAt(e.now, "c"), steamA)); !strings.HasSuffix(l, "login_error=state") {
		t.Errorf("forged state: %s", l)
	}
	if l := locationOf(e.openidReturn(state, cookie, nonceAt(e.now.Add(-6*time.Minute), "d"), steamA)); !strings.HasSuffix(l, "login_error=nonce_stale") {
		t.Errorf("old nonce: %s", l)
	}
	if l := locationOf(e.openidReturn(state, cookie, nonceAt(e.now, "e"), "1234")); !strings.HasSuffix(l, "login_error=claimed_id_format") {
		t.Errorf("short steam id: %s", l)
	}
	e.steam.valid = false
	if l := locationOf(e.openidReturn(state, cookie, nonceAt(e.now, "f"), steamA)); !strings.HasSuffix(l, "login_error=assertion_rejected") {
		t.Errorf("Steam says invalid: %s", l)
	}
	// A banned account is refused after Steam accepts the assertion.
	e.steam.valid = true
	_, prof := e.loginSteam(steamB)
	e.do("POST", "/admin/players/"+prof["player_id"].(string)+"/ban", map[string]string{"reason": "x"}, bearer(adminToken))
	if l := locationOf(e.openidReturn(state, cookie, nonceAt(e.now, "g"), steamB)); !strings.HasSuffix(l, "login_error=banned") {
		t.Errorf("banned: %s", l)
	}
	// The error never reveals more than a code, and no session is created for any of these.
	var n int
	_ = e.st.Pool().QueryRow(context.Background(), `SELECT count(*) FROM exchange_codes`).Scan(&n)
	if n != 0 {
		t.Errorf("%d exchange codes after refusals", n)
	}
	// Exchange input checks.
	for _, code := range []string{"", "short", strings.Repeat("a", 200)} {
		if r := e.do("POST", "/auth/exchange", map[string]string{"code": code}, nil); r.Status != 400 {
			t.Errorf("code %q: %d", code, r.Status)
		}
	}
	if r := e.do("POST", "/auth/exchange", map[string]string{"code": strings.Repeat("a", 43)}, nil); r.Status != 401 {
		t.Errorf("unknown code: %d", r.Status)
	}
}

func TestOpenIDExchangeCodeExpiresAfter60Seconds(t *testing.T) {
	e := newEnv(t, nil)
	state, cookie := e.openidStart()
	r := e.openidReturn(state, cookie, nonceAt(e.now, "z"), steamA)
	code := strings.TrimPrefix(r.Header.Get("Location"), publicURL+"/#code=")
	e.now = e.now.Add(61 * time.Second)
	if r := e.do("POST", "/auth/exchange", map[string]string{"code": code}, nil); r.Status != 401 {
		t.Errorf("after 61 s: %d", r.Status)
	}
}

// --- servers, tickets, settlement ---

type match struct {
	ID      string
	Seed    string
	Ranked  bool
	Tickets []map[string]any
}

func (e *env) assign(serverID string, players ...string) match {
	e.t.Helper()
	seats := []map[string]any{}
	for i, p := range players {
		seats = append(seats, map[string]any{"player_id": p, "seat": i, "ip_prefix": "10.0." + strconv.Itoa(i)})
	}
	r := e.do("POST", "/admin/matches", map[string]any{"server_id": serverID, "seats": seats, "game_version": "0.9", "sim_hash": "abc"}, bearer(adminToken))
	if r.Status != 201 {
		e.t.Fatalf("assign: %d %s", r.Status, r.Body)
	}
	j := r.json(e.t)
	m := match{ID: j["match_id"].(string), Seed: j["seed"].(string), Ranked: j["ranked"].(bool)}
	for _, t := range j["tickets"].([]any) {
		m.Tickets = append(m.Tickets, t.(map[string]any))
	}
	return m
}

func report(places map[string]int, abandoned ...string) map[string]any {
	ps := []map[string]any{}
	for id, p := range places {
		ab := false
		for _, a := range abandoned {
			ab = ab || a == id
		}
		ps = append(ps, map[string]any{"player_id": id, "place": p, "abandoned": ab})
	}
	return map[string]any{"players": ps}
}

func TestServerRegistrationAndHeartbeat(t *testing.T) {
	e := newEnv(t, nil)
	body := map[string]any{"name": "eu-1", "region": "eu", "url": "wss://eu.example.com", "capacity": 5}
	if r := e.do("POST", "/servers/register", body, nil); r.Status != 401 {
		t.Errorf("no token: %d", r.Status)
	}
	if r := e.do("POST", "/servers/register", body, bearer(adminToken)); r.Status != 401 {
		t.Errorf("the admin token is not the registration token: %d", r.Status)
	}
	for _, bad := range []map[string]any{
		{"name": "Bad Name", "region": "eu", "url": "wss://x", "capacity": 5},
		{"name": "a", "region": "eu", "url": "http://x", "capacity": 5},
		{"name": "a", "region": "eu", "url": "wss://x", "capacity": 0},
	} {
		if r := e.do("POST", "/servers/register", bad, bearer(registerToken)); r.Status != 400 {
			t.Errorf("%v: %d", bad, r.Status)
		}
	}
	id, key := e.registerServer()
	if len(key) != 64 {
		t.Fatalf("key %q", key)
	}
	if r := e.do("POST", "/servers/heartbeat", map[string]any{"capacity": 1}, nil); r.Status != 401 {
		t.Errorf("no credentials: %d", r.Status)
	}
	if r := e.do("POST", "/servers/heartbeat", map[string]any{"capacity": 1}, serverAuth(id, strings.Repeat("0", 64))); r.Status != 401 {
		t.Errorf("wrong key: %d", r.Status)
	}
	if r := e.do("POST", "/servers/heartbeat", map[string]any{"capacity": -1}, serverAuth(id, key)); r.Status != 400 {
		t.Errorf("bad heartbeat: %d", r.Status)
	}
	if r := e.do("POST", "/servers/heartbeat", map[string]any{"capacity": 1, "metrics": "not an object"}, serverAuth(id, key)); r.Status != 400 {
		t.Errorf("metrics: %d", r.Status)
	}
}

func TestMatchTicketsAreSignedWithTheServerKey(t *testing.T) {
	e := newEnv(t, nil)
	e.persona.Names[steamA] = "Alice"
	_, pa := e.loginSteam(steamA)
	_, pb := e.loginSteam(steamB)
	sid, keyHex := e.registerServer()
	key, _ := hex.DecodeString(keyHex)
	m := e.assign(sid, pa["player_id"].(string), pb["player_id"].(string))
	if len(m.Tickets) != 2 {
		t.Fatal(m)
	}
	tk, err := ticket.Verify(key, m.Tickets[0]["ticket"].(string), e.now)
	if err != nil {
		t.Fatal(err)
	}
	seed, _ := strconv.ParseInt(m.Seed, 10, 64)
	if tk.MatchID != m.ID || tk.Seat != 0 || tk.PlayerID != pa["player_id"] || tk.SteamID != steamA || tk.Name != "ALICE" || tk.Seed != seed || tk.ServerID != sid {
		t.Errorf("ticket %+v", tk)
	}
	if tk.Expires != e.now.Add(60*time.Second).Unix() {
		t.Errorf("expires %d", tk.Expires)
	}
	// The ticket does not verify with another server's key or after 60 s.
	other := append([]byte{}, key...)
	other[0] ^= 0xff
	if _, err := ticket.Verify(other, m.Tickets[0]["ticket"].(string), e.now); err == nil {
		t.Error("verifies with another key")
	}
	if _, err := ticket.Verify(key, m.Tickets[0]["ticket"].(string), e.now.Add(61*time.Second)); err == nil {
		t.Error("verifies after expiry")
	}
	// Admin-only.
	if r := e.do("POST", "/admin/matches", map[string]any{}, nil); r.Status != 401 {
		t.Errorf("assign without admin token: %d", r.Status)
	}
	if r := e.do("POST", "/admin/matches", map[string]any{}, bearer("wrong-token-wrong-token-wrong")); r.Status != 401 {
		t.Errorf("assign with a wrong token: %d", r.Status)
	}
}

func TestGuestTicketCarriesNoSteamID(t *testing.T) {
	e := newEnv(t, nil)
	sid, keyHex := e.registerServer()
	key, _ := hex.DecodeString(keyHex)
	g := e.do("POST", "/auth/guest", nil, nil).json(t)["profile"].(map[string]any)["player_id"].(string)
	_, pa := e.loginSteam(steamA)
	m := e.assign(sid, g, pa["player_id"].(string))
	tk, err := ticket.Verify(key, m.Tickets[0]["ticket"].(string), e.now)
	if err != nil || !tk.Guest() || tk.SteamID != "" || tk.Name != "" {
		t.Errorf("%+v %v", tk, err)
	}
	if m.Ranked {
		t.Error("a guest and one Steam human: fewer than 2 ranked humans")
	}
}

func TestResultSettlementOverHTTP(t *testing.T) {
	e := newEnv(t, nil)
	ta, pa := e.loginSteam(steamA)
	tb, pb := e.loginSteam(steamB)
	ida, idb := pa["player_id"].(string), pb["player_id"].(string)
	sid, key := e.registerServer()
	m := e.assign(sid, ida, idb)
	if !m.Ranked {
		t.Fatal("two bronze humans must rank")
	}
	path := "/matches/" + m.ID + "/result"
	rep := report(map[string]int{ida: 1, idb: 2})

	if r := e.do("POST", path, rep, nil); r.Status != 401 {
		t.Errorf("no key: %d", r.Status)
	}
	if r := e.do("POST", path, rep, bearer(ta)); r.Status != 401 {
		t.Errorf("a player's session is not a server key: %d", r.Status)
	}
	// Another registered server cannot report this match.
	r2 := e.do("POST", "/servers/register", map[string]any{"name": "us-1", "region": "us", "url": "wss://us.example.com", "capacity": 5}, bearer(registerToken)).json(t)
	if r := e.do("POST", path, rep, serverAuth(r2["server_id"].(string), r2["key"].(string))); r.Status != 403 {
		t.Errorf("wrong server: %d", r.Status)
	}
	// Malformed and out-of-assignment reports.
	if r := e.do("POST", path, map[string]any{"players": []map[string]any{{"player_id": ida, "place": 1}}}, serverAuth(sid, key)); r.Status != 400 {
		t.Errorf("missing player: %d", r.Status)
	}
	if r := e.do("POST", path, map[string]any{"players": []map[string]any{{"player_id": ida, "place": 1, "points": 999}, {"player_id": idb, "place": 2}}}, serverAuth(sid, key)); r.Status != 400 {
		t.Errorf("a server cannot send points: %d", r.Status)
	}
	if r := e.do("POST", "/matches/abc/result", rep, serverAuth(sid, key)); r.Status != 400 {
		t.Errorf("bad id: %d", r.Status)
	}
	if r := e.do("POST", "/matches/99999/result", rep, serverAuth(sid, key)); r.Status != 404 {
		t.Errorf("unknown match: %d", r.Status)
	}

	r := e.do("POST", path, rep, serverAuth(sid, key))
	if r.Status != 200 {
		t.Fatalf("settle: %d %s", r.Status, r.Body)
	}
	j := r.json(t)
	if j["ranked"] != true || j["already_settled"] != false {
		t.Errorf("%v", j)
	}
	// Idempotent.
	again := e.do("POST", path, rep, serverAuth(sid, key))
	if again.Status != 200 || again.json(t)["already_settled"] != true {
		t.Errorf("repeat: %d %s", again.Status, again.Body)
	}
	// A different result: 409.
	if r := e.do("POST", path, report(map[string]int{ida: 2, idb: 1}), serverAuth(sid, key)); r.Status != 409 {
		t.Errorf("different result: %d %s", r.Status, r.Body)
	}
	me := e.do("GET", "/me", nil, bearer(ta)).json(t)
	if me["points"].(float64) != 20 || me["rank"].(float64) != 1 || me["ranked_matches"].(float64) != 1 {
		t.Errorf("winner %v", me)
	}
	me2 := e.do("GET", "/me", nil, bearer(tb)).json(t)
	if me2["points"].(float64) != 0 || me2["rank"].(float64) != 2 {
		t.Errorf("loser (floor 0) %v", me2)
	}
	var alerts int
	_ = e.st.Pool().QueryRow(context.Background(), `SELECT count(*) FROM audit WHERE kind = 'result_conflict' AND severity = 'alert'`).Scan(&alerts)
	if alerts != 1 {
		t.Errorf("alerts: %d", alerts)
	}

	// Leaderboard.
	lb := e.do("GET", "/leaderboard?limit=5", nil, nil).json(t)["entries"].([]any)
	if len(lb) != 2 || lb[0].(map[string]any)["points"].(float64) != 20 || lb[0].(map[string]any)["name"] == nil {
		t.Errorf("leaderboard %v", lb)
	}
	if r := e.do("GET", "/leaderboard?limit=abc", nil, nil); r.Status != 400 {
		t.Errorf("limit=abc: %d", r.Status)
	}
	if _, leaks := lb[0].(map[string]any)["steam_id"]; leaks {
		t.Error("the leaderboard must not expose SteamIDs")
	}

	// Admin annul takes back exactly the applied deltas.
	if r := e.do("POST", "/admin/matches/"+m.ID+"/annul", map[string]string{"reason": "test"}, nil); r.Status != 401 {
		t.Errorf("annul without token: %d", r.Status)
	}
	if r := e.do("POST", "/admin/matches/"+m.ID+"/annul", map[string]string{}, bearer(adminToken)); r.Status != 400 {
		t.Errorf("annul without reason: %d", r.Status)
	}
	ar := e.do("POST", "/admin/matches/"+m.ID+"/annul", map[string]string{"reason": "test"}, bearer(adminToken))
	if ar.Status != 200 || ar.json(t)["status"] != "annulled" {
		t.Fatalf("annul: %d %s", ar.Status, ar.Body)
	}
	if me := e.do("GET", "/me", nil, bearer(ta)).json(t); me["points"].(float64) != 0 || me["ranked_matches"].(float64) != 0 {
		t.Errorf("after annul %v", me)
	}
	if r := e.do("POST", path, rep, serverAuth(sid, key)); r.Status != 410 {
		t.Errorf("result after annul: %d", r.Status)
	}
	info := e.do("GET", "/admin/matches/"+m.ID, nil, bearer(adminToken)).json(t)
	if info["status"] != "annulled" {
		t.Errorf("%v", info)
	}
}

func TestReplayUpload(t *testing.T) {
	e := newEnv(t, func(m map[string]string) { m["REPLAY_MAX_BYTES"] = "1024" })
	_, pa := e.loginSteam(steamA)
	_, pb := e.loginSteam(steamB)
	sid, key := e.registerServer()
	m := e.assign(sid, pa["player_id"].(string), pb["player_id"].(string))
	path := "/matches/" + m.ID + "/replay"
	data := bytes.Repeat([]byte{0x1f, 0x8b, 0x08}, 100)
	hdr := serverAuth(sid, key)
	hdr["X-Replay-Format"] = "gzip"
	if r := e.do("POST", path, data, hdr); r.Status != 201 {
		t.Fatalf("upload: %d %s", r.Status, r.Body)
	}
	if r := e.do("POST", path, data, hdr); r.Status != 200 {
		t.Errorf("same upload again: %d", r.Status)
	}
	if r := e.do("POST", path, []byte("different"), hdr); r.Status != 409 {
		t.Errorf("different upload: %d", r.Status)
	}
	if r := e.do("POST", path, bytes.Repeat([]byte{1}, 2000), hdr); r.Status != 413 && r.Status != 409 {
		t.Errorf("too big: %d", r.Status)
	}
	if r := e.do("POST", path, []byte{}, hdr); r.Status != 400 {
		t.Errorf("empty: %d", r.Status)
	}
	if r := e.do("POST", path, data, serverAuth(sid, "00")); r.Status != 401 {
		t.Errorf("no key: %d", r.Status)
	}
	got := e.do("GET", "/admin/matches/"+m.ID+"/replay", nil, bearer(adminToken))
	if got.Status != 200 || !bytes.Equal(got.Body, data) || got.Header.Get("X-Replay-Format") != "gzip" {
		t.Errorf("download: %d", got.Status)
	}
	if r := e.do("GET", "/admin/matches/"+m.ID+"/replay", nil, nil); r.Status != 401 {
		t.Errorf("download without admin: %d", r.Status)
	}
}

func TestAccountDeleteAndExport(t *testing.T) {
	e := newEnv(t, nil)
	ta, pa := e.loginSteam(steamA)
	_, pb := e.loginSteam(steamB)
	ida, idb := pa["player_id"].(string), pb["player_id"].(string)
	sid, key := e.registerServer()
	m := e.assign(sid, ida, idb)

	// In an open match the account cannot be deleted.
	if r := e.do("POST", "/account/delete", map[string]string{"confirm": "DELETE"}, bearer(ta)); r.Status != 409 {
		t.Errorf("delete during match: %d", r.Status)
	}
	e.do("POST", "/matches/"+m.ID+"/result", report(map[string]int{ida: 1, idb: 2}), serverAuth(sid, key))
	if r := e.do("POST", "/reports", map[string]string{"target_player_id": idb, "match_id": m.ID, "reason": "idles"}, bearer(ta)); r.Status != 201 {
		t.Errorf("report: %d %s", r.Status, r.Body)
	}
	for _, bad := range []map[string]string{
		{"target_player_id": ida, "reason": "myself"}, {"target_player_id": idb, "reason": ""},
		{"target_player_id": "x", "reason": "r"}, {"target_player_id": idb, "reason": strings.Repeat("a", 201)},
	} {
		if r := e.do("POST", "/reports", bad, bearer(ta)); r.Status != 400 {
			t.Errorf("report %v: %d", bad, r.Status)
		}
	}
	if r := e.do("POST", "/reports", map[string]string{"target_player_id": "99999", "reason": "r"}, bearer(ta)); r.Status != 404 {
		t.Errorf("report of unknown player: %d", r.Status)
	}

	ex := e.do("GET", "/account/export", nil, bearer(ta))
	if ex.Status != 200 || !strings.Contains(ex.Header.Get("Content-Disposition"), "attachment") {
		t.Fatalf("export: %d", ex.Status)
	}
	exj := ex.json(t)
	if exj["player"].(map[string]any)["steam_id"] != steamA || len(exj["matches"].([]any)) != 1 || len(exj["reports_made"].([]any)) != 1 {
		t.Errorf("export %v", exj)
	}
	if r := e.do("GET", "/account/export", nil, nil); r.Status != 401 {
		t.Errorf("export without session: %d", r.Status)
	}

	if r := e.do("POST", "/account/delete", map[string]string{"confirm": "yes"}, bearer(ta)); r.Status != 400 {
		t.Errorf("delete without the exact confirmation: %d", r.Status)
	}
	if r := e.do("POST", "/account/delete", map[string]string{"confirm": "DELETE"}, bearer(ta)); r.Status != 200 {
		t.Fatalf("delete: %d %s", r.Status, r.Body)
	}
	if r := e.do("GET", "/me", nil, bearer(ta)); r.Status != 401 {
		t.Errorf("session after deletion: %d", r.Status)
	}
	var rows int
	_ = e.st.Pool().QueryRow(context.Background(), `SELECT (SELECT count(*) FROM ratings WHERE player_id = $1)
		+ (SELECT count(*) FROM match_players WHERE player_id = $1) + (SELECT count(*) FROM reports WHERE reporter = $1)`, ida).Scan(&rows)
	if rows != 0 {
		t.Errorf("%d rows left", rows)
	}
	lb := e.do("GET", "/leaderboard", nil, nil).json(t)["entries"].([]any)
	for _, x := range lb {
		if x.(map[string]any)["player_id"] == ida {
			t.Error("the deleted account is still on the leaderboard")
		}
	}
}

func TestHealthAndHeaders(t *testing.T) {
	e := newEnv(t, nil)
	if r := e.do("GET", "/healthz", nil, nil); r.Status != 200 {
		t.Error("healthz")
	}
	r := e.do("GET", "/readyz", nil, nil)
	if r.Status != 200 {
		t.Error("readyz")
	}
	if r.Header.Get("X-Content-Type-Options") != "nosniff" {
		t.Error("headers")
	}
	if r := e.do("GET", "/nope", nil, nil); r.Status != 404 {
		t.Error("404")
	}
	if r := e.do("DELETE", "/me", nil, nil); r.Status != 405 {
		t.Errorf("method: %d", r.Status)
	}
}
