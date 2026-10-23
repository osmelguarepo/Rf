package api_test

import (
	"context"
	"encoding/hex"
	"fmt"
	"strings"
	"testing"
	"time"

	"fuelrivals/backend/internal/ticket"
)

func queueEnv(t *testing.T, extra map[string]string) *env {
	return newEnv(t, func(m map[string]string) {
		m["LEASE_TTL"] = "1h"     // the test clock jumps; the game server stays alive
		m["TRUST_PROXY"] = "true" // each test player comes from its own /24 through X-Forwarded-For
		for k, v := range extra {
			m[k] = v
		}
	})
}

func (e *env) tick() { e.srv.Matchmaker().Tick(context.Background()) }

// advance moves the clock and runs the matching loop once.
func (e *env) advance(d time.Duration) {
	e.now = e.now.Add(d)
	e.tick()
}

func hdr(tok string, subnet int) map[string]string {
	return map[string]string{"Authorization": "Bearer " + tok, "X-Forwarded-For": fmt.Sprintf("10.%d.%d.7", subnet/250, subnet%250)}
}

type racer struct {
	tok    string
	id     string
	subnet int
}

// steamRacer logs in a Steam account (n is 1..99) from its own subnet.
func (e *env) steamRacer(n int) racer {
	e.t.Helper()
	tok, prof := e.loginSteam(fmt.Sprintf("765611980000%05d", n))
	return racer{tok: tok, id: prof["player_id"].(string), subnet: n}
}

func (e *env) guestRacer(n int) racer {
	e.t.Helper()
	r := e.do("POST", "/auth/guest", nil, nil)
	if r.Status != 200 {
		e.t.Fatalf("guest: %d %s", r.Status, r.Body)
	}
	j := r.json(e.t)
	return racer{tok: j["token"].(string), id: j["profile"].(map[string]any)["player_id"].(string), subnet: 100 + n}
}

func (e *env) enterQueue(r racer, lat map[string]int) resp {
	return e.do("POST", "/queue", map[string]any{"latencies": lat}, hdr(r.tok, r.subnet))
}

func (e *env) status(r racer) map[string]any {
	e.t.Helper()
	res := e.do("GET", "/queue/status", nil, hdr(r.tok, r.subnet))
	if res.Status != 200 {
		e.t.Fatalf("status: %d %s", res.Status, res.Body)
	}
	return res.json(e.t)
}

func (e *env) confirm(r racer) resp {
	st := e.status(r)
	m, ok := st["match"].(map[string]any)
	if !ok {
		e.t.Fatalf("no match to confirm: %v", st)
	}
	return e.do("POST", "/queue/ready", map[string]string{"match_id": m["match_id"].(string)}, hdr(r.tok, r.subnet))
}

// startMatch queues the racers, waits for the match, confirms and starts it. It returns the match id.
func (e *env) startMatch(rs ...racer) string {
	e.t.Helper()
	for _, r := range rs {
		if res := e.enterQueue(r, map[string]int{"eu": 30}); res.Status != 200 {
			e.t.Fatalf("enter: %d %s", res.Status, res.Body)
		}
	}
	e.advance(31 * time.Second)
	for _, r := range rs {
		if st := e.status(r); st["state"] != "found" {
			e.t.Fatalf("expected found: %v", st)
		}
		if res := e.confirm(r); res.Status != 200 {
			e.t.Fatalf("ready: %d %s", res.Status, res.Body)
		}
	}
	e.advance(time.Second)
	st := e.status(rs[0])
	if st["state"] != "starting" {
		e.t.Fatalf("expected starting: %v", st)
	}
	return st["match"].(map[string]any)["match_id"].(string)
}

func (e *env) join(r racer, matchID string) resp {
	return e.do("GET", "/match/"+matchID+"/join", nil, hdr(r.tok, r.subnet))
}

// The whole path: guests and Steam accounts -> queue -> found -> ready -> starting -> join ticket (verified with the
// ticket package) -> the simulated game server posts a result -> settlement.
func TestEndToEndQueueToSettlement(t *testing.T) {
	e := queueEnv(t, map[string]string{"METRICS_TOKEN": "metrics-token-0123456789"})
	serverID, key := e.registerServer()
	keyBytes, _ := hex.DecodeString(key)

	a, b, c := e.steamRacer(1), e.steamRacer(2), e.steamRacer(3)

	// Before anything: idle.
	if st := e.status(a); st["state"] != "idle" {
		t.Fatalf("%v", st)
	}
	res := e.enterQueue(a, map[string]int{"eu": 30, "us": 120})
	if res.Status != 200 || res.json(t)["queue_id"] == "" {
		t.Fatalf("%d %s", res.Status, res.Body)
	}
	for _, r := range []racer{b, c} {
		if res := e.enterQueue(r, map[string]int{"eu": 25}); res.Status != 200 {
			t.Fatalf("%d %s", res.Status, res.Body)
		}
	}
	e.advance(5 * time.Second)
	st := e.status(a)
	if st["state"] != "waiting" || st["wait_s"].(float64) != 5 || st["band_divisions"].(float64) != 1 || st["players_found"].(float64) != 3 {
		t.Fatalf("waiting: %v", st)
	}
	if st["match"] != nil {
		t.Error("no match yet")
	}

	// Three humans wait until the oldest has waited 30 s.
	e.advance(26 * time.Second)
	for _, r := range []racer{a, b, c} {
		st := e.status(r)
		m, _ := st["match"].(map[string]any)
		if st["state"] != "found" || m == nil || st["players_found"].(float64) != 3 {
			t.Fatalf("found: %v", st)
		}
		deadline := int64(m["ready_deadline_unix"].(float64))
		if deadline != e.now.Add(15*time.Second).Unix() {
			t.Errorf("ready deadline %d", deadline)
		}
	}
	// Joining before the match starts is refused (it does not exist yet).
	mid := e.status(a)["match"].(map[string]any)["match_id"].(string)
	if r := e.join(a, mid); r.Status != 404 {
		t.Errorf("join before start: %d %s", r.Status, r.Body)
	}
	// A ready from somebody else's match id is refused.
	if r := e.do("POST", "/queue/ready", map[string]string{"match_id": "424242"}, hdr(a.tok, a.subnet)); r.Status != 404 {
		t.Errorf("wrong match id: %d", r.Status)
	}
	if r := e.confirm(a); r.Status != 200 || r.json(t)["state"] != "ready" {
		t.Fatalf("confirm: %d %s", r.Status, r.Body)
	}
	e.confirm(b)
	e.advance(time.Second)
	if st := e.status(a); st["state"] != "ready" || st["players_confirmed"].(float64) != 2 {
		t.Fatalf("two of three: %v", st)
	}
	e.confirm(c)
	e.advance(time.Second)
	for _, r := range []racer{a, b, c} {
		if st := e.status(r); st["state"] != "starting" || st["match"].(map[string]any)["match_id"] != mid {
			t.Fatalf("starting: %v", st)
		}
	}

	// The tickets verify with the server's key and carry the right seat, server and match.
	seen := map[int]bool{}
	var tickets []ticket.Ticket
	for _, r := range []racer{a, b, c} {
		j := e.join(r, mid)
		if j.Status != 200 {
			t.Fatalf("join: %d %s", j.Status, j.Body)
		}
		body := j.json(t)
		tk, err := ticket.Verify(keyBytes, body["ticket"].(string), e.now)
		if err != nil {
			t.Fatalf("ticket does not verify: %v", err)
		}
		if body["ws_url"] != "wss://eu.example.com" || tk.MatchID != mid || tk.PlayerID != r.id || tk.ServerID != serverID || seen[tk.Seat] {
			t.Fatalf("ticket %+v body %v", tk, body)
		}
		seen[tk.Seat] = true
		tickets = append(tickets, tk)
		// Within the minute, asking again gives the very same ticket; the 60 s are counted from the first request.
		if again := e.join(r, mid).json(t); again["ticket"] != body["ticket"] {
			t.Error("the same ticket is returned inside its validity")
		}
	}
	// "starting" is gone once the ticket was fetched.
	if st := e.status(a); st["state"] != "idle" {
		t.Errorf("after join: %v", st)
	}
	// A ticket from another server's key does not verify (a game server only trusts its own key).
	if _, err := ticket.Verify([]byte("another key of 32 bytes.........."), e.join(a, mid).json(t)["ticket"].(string), e.now); err == nil {
		t.Error("foreign key verified")
	}
	// Strangers cannot join; a player in a match cannot queue.
	d := e.steamRacer(4)
	if r := e.join(d, mid); r.Status != 404 {
		t.Errorf("stranger: %d", r.Status)
	}
	if r := e.enterQueue(a, nil); r.Status != 409 {
		t.Errorf("queue while in a match: %d %s", r.Status, r.Body)
	}

	// The match record: 3 humans, 3 bots, ranked (three Steam accounts of one division from different subnets).
	am := e.do("GET", "/admin/matches/"+mid, nil, bearer(adminToken)).json(t)
	if am["status"] != "assigned" || am["ranked"] != true || len(am["player_ids"].([]any)) != 3 {
		t.Fatalf("%v", am)
	}
	list := e.do("GET", "/admin/matches?status=assigned", nil, bearer(adminToken)).json(t)["matches"].([]any)
	if len(list) != 1 || list[0].(map[string]any)["bots"].(float64) != 3 || list[0].(map[string]any)["humans"].(float64) != 3 {
		t.Fatalf("%v", list)
	}

	// The simulated game server posts the result: a wins, b second, c last. 3 humans: +25, 0, -25 (floor 0).
	places := map[string]int{a.id: 1, b.id: 2, c.id: 3}
	var entries []map[string]any
	for _, tk := range tickets {
		entries = append(entries, map[string]any{"player_id": tk.PlayerID, "place": places[tk.PlayerID]})
	}
	rr := e.do("POST", "/matches/"+mid+"/result", map[string]any{"players": entries}, serverAuth(serverID, key))
	if rr.Status != 200 {
		t.Fatalf("result: %d %s", rr.Status, rr.Body)
	}
	if me := e.do("GET", "/me", nil, hdr(a.tok, a.subnet)).json(t); me["points"].(float64) != 25 {
		t.Errorf("winner points %v", me["points"])
	}
	if me := e.do("GET", "/me", nil, hdr(c.tok, c.subnet)).json(t); me["points"].(float64) != 0 {
		t.Errorf("last place points %v", me["points"])
	}
	// Settled: they can queue again, and joining the finished match is refused.
	if r := e.enterQueue(a, nil); r.Status != 200 {
		t.Errorf("queue after the match: %d %s", r.Status, r.Body)
	}
	if r := e.join(b, mid); r.Status != 409 {
		t.Errorf("join a finished match: %d %s", r.Status, r.Body)
	}

	// Telemetry: the funnel, wait times, bot share; behind the token.
	if r := e.do("GET", "/metrics", nil, nil); r.Status != 401 {
		t.Errorf("metrics without token: %d", r.Status)
	}
	m := e.do("GET", "/metrics", nil, bearer("metrics-token-0123456789"))
	if m.Status != 200 || !strings.HasPrefix(m.Header.Get("Content-Type"), "text/plain") {
		t.Fatalf("metrics: %d %v", m.Status, m.Header)
	}
	body := string(m.Body)
	for _, want := range []string{
		`fr_funnel_total{stage="session"}`, `fr_funnel_total{stage="queued"} 4`, `fr_funnel_total{stage="found"} 3`,
		`fr_funnel_total{stage="ready"} 3`, `fr_funnel_total{stage="started"} 3`, `fr_funnel_total{stage="finished"} 3`,
		`fr_matches_started_total{filled="bots"} 1`, `fr_match_bots_total 3`, `fr_queue_wait_seconds_count 3`,
		`fr_queue_wait_seconds_bucket{le="30"}`, `fr_http_requests_total{route="POST /queue",status="200"}`, "fr_queue_size 1",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("metrics lack %q", want)
		}
	}
}

func TestMetricsDisabledWithoutToken(t *testing.T) {
	e := queueEnv(t, nil)
	if r := e.do("GET", "/metrics", nil, bearer("whatever")); r.Status != 404 {
		t.Errorf("%d", r.Status)
	}
}

func TestQueueRequestRules(t *testing.T) {
	e := queueEnv(t, nil)
	e.registerServer()
	a := e.steamRacer(1)
	if r := e.do("POST", "/queue", nil, nil); r.Status != 401 {
		t.Errorf("no token: %d", r.Status)
	}
	if r := e.do("GET", "/queue/status", nil, nil); r.Status != 401 {
		t.Errorf("no token: %d", r.Status)
	}
	// An empty body is fine; bad bodies are not.
	if r := e.do("POST", "/queue", nil, hdr(a.tok, 1)); r.Status != 200 {
		t.Errorf("empty body: %d %s", r.Status, r.Body)
	}
	id1 := e.enterQueue(a, map[string]int{"eu": 20}).json(t)["queue_id"]
	if id2 := e.enterQueue(a, map[string]int{"eu": 20}).json(t)["queue_id"]; id1 != id2 {
		t.Error("asking twice returns the same queue id")
	}
	for _, body := range []any{`{"latencies": {"EU!": 5}}`, `{"latencies": {"eu": "fast"}}`, `{"surprise": 1}`, `[]`, `{"sim_hash": "` + strings.Repeat("a", 70) + `"}`} {
		if r := e.do("POST", "/queue", body, hdr(a.tok, 1)); r.Status != 400 {
			t.Errorf("%v: %d", body, r.Status)
		}
	}
	if r := e.do("POST", "/queue/ready", map[string]string{"match_id": "abc"}, hdr(a.tok, 1)); r.Status != 400 {
		t.Errorf("bad match id: %d", r.Status)
	}
	if r := e.do("POST", "/queue/ready", map[string]string{"match_id": "5"}, hdr(a.tok, 1)); r.Status != 404 {
		t.Errorf("not found: %d", r.Status)
	}
	// DELETE leaves; leaving again is harmless.
	if r := e.do("DELETE", "/queue", nil, hdr(a.tok, 1)); r.Status != 200 || r.json(t)["was"] != "waiting" {
		t.Errorf("%d %s", r.Status, r.Body)
	}
	if r := e.do("DELETE", "/queue", nil, hdr(a.tok, 1)); r.Status != 200 || r.json(t)["was"] != "idle" {
		t.Errorf("%d %s", r.Status, r.Body)
	}
	if st := e.status(a); st["state"] != "idle" {
		t.Errorf("%v", st)
	}
	if r := e.do("GET", "/match/abc/join", nil, hdr(a.tok, 1)); r.Status != 400 {
		t.Errorf("%d", r.Status)
	}
	if r := e.do("POST", "/match/777/leave", nil, hdr(a.tok, 1)); r.Status != 404 {
		t.Errorf("%d", r.Status)
	}
}

func TestLoneGuestRacesAgainstBotsAndNeverRanks(t *testing.T) {
	e := queueEnv(t, map[string]string{"QUEUE_SOLO_WAIT": "20s"})
	sid, key := e.registerServer()
	g := e.guestRacer(1)
	e.enterQueue(g, map[string]int{"eu": 40})
	e.advance(19 * time.Second)
	if st := e.status(g); st["state"] != "waiting" {
		t.Fatalf("%v", st)
	}
	e.advance(time.Second)
	if st := e.status(g); st["state"] != "found" || st["players_found"].(float64) != 1 {
		t.Fatalf("%v", st)
	}
	e.confirm(g)
	e.advance(time.Second)
	st := e.status(g)
	if st["state"] != "starting" {
		t.Fatalf("%v", st)
	}
	mid := st["match"].(map[string]any)["match_id"].(string)
	am := e.do("GET", "/admin/matches/"+mid, nil, bearer(adminToken)).json(t)
	if am["ranked"] != false || am["rank_reason"] != "fewer_than_2_ranked_humans" {
		t.Fatalf("%v", am)
	}
	lst := e.do("GET", "/admin/matches", nil, bearer(adminToken)).json(t)["matches"].([]any)[0].(map[string]any)
	if lst["humans"].(float64) != 1 || lst["bots"].(float64) != 5 {
		t.Errorf("%v", lst)
	}
	tk := e.join(g, mid).json(t)["ticket"].(string)
	kb, _ := hex.DecodeString(key)
	if parsed, err := ticket.Verify(kb, tk, e.now); err != nil || !parsed.Guest() || parsed.ServerID != sid {
		t.Fatalf("%+v %v", parsed, err)
	}
	// The result for a lone human changes nothing.
	r := e.do("POST", "/matches/"+mid+"/result", map[string]any{"players": []map[string]any{{"player_id": g.id, "place": 3}}}, serverAuth(sid, key))
	if r.Status != 200 || r.json(t)["ranked"] != false {
		t.Fatalf("%d %s", r.Status, r.Body)
	}
}

func TestSameSubnetAndMixedGuestsRankDecidedAtAssignment(t *testing.T) {
	e := queueEnv(t, nil)
	e.registerServer()
	a, b := e.steamRacer(1), e.steamRacer(2)
	b.subnet = a.subnet // same /24
	mid := e.startMatch(a, b)
	am := e.do("GET", "/admin/matches/"+mid, nil, bearer(adminToken)).json(t)
	if am["ranked"] != false || am["rank_reason"] != "same_subnet" {
		t.Fatalf("%v", am)
	}
	// Two Steam accounts and a guest: the guest is ignored by the rule, the two Steam accounts rank.
	e2 := queueEnv(t, nil)
	e2.registerServer()
	x, y, g := e2.steamRacer(1), e2.steamRacer(2), e2.guestRacer(3)
	mid = e2.startMatch(x, y, g)
	am = e2.do("GET", "/admin/matches/"+mid, nil, bearer(adminToken)).json(t)
	if am["ranked"] != true || len(am["player_ids"].([]any)) != 3 {
		t.Fatalf("%v", am)
	}
}

func TestJoinTicketLifetimeAndLeave(t *testing.T) {
	e := queueEnv(t, nil)
	e.registerServer()
	a, b := e.steamRacer(1), e.steamRacer(2)
	mid := e.startMatch(a, b)

	first := e.join(a, mid).json(t)["ticket"]
	e.now = e.now.Add(59 * time.Second)
	if e.join(a, mid).json(t)["ticket"] != first {
		t.Error("same ticket inside the minute")
	}
	e.now = e.now.Add(2 * time.Second)
	if r := e.join(a, mid); r.Status != 409 || r.json(t)["error"] != "ticket_expired" {
		t.Errorf("after the minute: %d %s", r.Status, r.Body)
	}

	// A leaves: it is an abandon (a strike), A may queue again, B is still in the match.
	if r := e.do("POST", "/match/"+mid+"/leave", nil, hdr(a.tok, a.subnet)); r.Status != 200 || r.json(t)["match_status"] != "assigned" {
		t.Fatalf("leave: %d %s", r.Status, r.Body)
	}
	if r := e.do("POST", "/match/"+mid+"/leave", nil, hdr(a.tok, a.subnet)); r.json(t)["already"] != true {
		t.Errorf("leave twice: %s", r.Body)
	}
	if r := e.join(a, mid); r.Status != 409 {
		t.Errorf("join after leaving: %d", r.Status)
	}
	if r := e.enterQueue(a, nil); r.Status != 200 {
		t.Errorf("A is free after leaving: %d %s", r.Status, r.Body)
	}
	if r := e.enterQueue(b, nil); r.Status != 409 {
		t.Errorf("B is still in the match: %d", r.Status)
	}
	// B leaves too: the match is void and B is free.
	if r := e.do("POST", "/match/"+mid+"/leave", nil, hdr(b.tok, b.subnet)); r.json(t)["match_status"] != "void" {
		t.Errorf("%s", r.Body)
	}
	if r := e.enterQueue(b, nil); r.Status != 200 {
		t.Errorf("B after the void: %d", r.Status)
	}
	if r := e.join(b, mid); r.Status != 409 && r.Status != 410 {
		t.Errorf("join a void match: %d", r.Status)
	}
}

func TestRepeatLeaversGetAQueueBan(t *testing.T) {
	e := queueEnv(t, nil)
	e.registerServer()
	p := e.guestRacer(1)
	// PENALTY_FREE_STRIKES = 2: the third leave closes the queue for 5 minutes.
	for i := 0; i < 3; i++ {
		if r := e.enterQueue(p, map[string]int{"eu": 10}); r.Status != 200 {
			t.Fatalf("round %d: %d %s", i, r.Status, r.Body)
		}
		e.advance(31 * time.Second)
		e.confirm(p)
		e.advance(time.Second)
		st := e.status(p)
		if st["state"] != "starting" {
			t.Fatalf("round %d: %v", i, st)
		}
		mid := st["match"].(map[string]any)["match_id"].(string)
		if r := e.do("POST", "/match/"+mid+"/leave", nil, hdr(p.tok, p.subnet)); r.Status != 200 {
			t.Fatal(r.Status, string(r.Body))
		}
	}
	r := e.enterQueue(p, nil)
	j := r.json(t)
	if r.Status != 403 || j["error"] != "queue_banned" || j["retry_after_s"].(float64) < 290 || r.Header.Get("Retry-After") == "" {
		t.Fatalf("%d %s", r.Status, r.Body)
	}
	// An admin lifting the penalty lets the player in; so does time. (Guests have no unban path; use the clock.)
	e.now = e.now.Add(5*time.Minute + time.Second)
	if r := e.enterQueue(p, nil); r.Status != 200 {
		t.Fatalf("after the ban: %d %s", r.Status, r.Body)
	}
	// The strikes are stored, not only in memory.
	var strikes int
	if err := e.st.Pool().QueryRow(context.Background(), `SELECT strikes FROM leave_strikes WHERE player_id = $1`, mustInt(t, p.id)).Scan(&strikes); err != nil || strikes != 3 {
		t.Errorf("stored strikes %d %v", strikes, err)
	}
}

func mustInt(t *testing.T, s string) int64 {
	var n int64
	if _, err := fmt.Sscan(s, &n); err != nil {
		t.Fatal(err)
	}
	return n
}

func TestQueueAndStatusRateLimits(t *testing.T) {
	e := queueEnv(t, map[string]string{"RATE_QUEUE_PER_MIN": "4", "RATE_STATUS_PER_MIN": "6"})
	a := e.guestRacer(1)
	b := e.guestRacer(2)
	// Queue: burst max(4/2, 3) = 3.
	for i := 0; i < 3; i++ {
		if r := e.enterQueue(a, nil); r.Status != 200 {
			t.Fatalf("%d: %d", i, r.Status)
		}
	}
	r := e.enterQueue(a, nil)
	if r.Status != 429 || r.Header.Get("Retry-After") == "" {
		t.Fatalf("4th: %d %v", r.Status, r.Header)
	}
	if r := e.do("DELETE", "/queue", nil, hdr(a.tok, a.subnet)); r.Status != 429 {
		t.Errorf("DELETE shares the budget: %d", r.Status)
	}
	// Another account has its own budget.
	if r := e.enterQueue(b, nil); r.Status != 200 {
		t.Errorf("other account: %d", r.Status)
	}
	// Status: burst max(6/3, 5) = 5.
	for i := 0; i < 5; i++ {
		if r := e.do("GET", "/queue/status", nil, hdr(b.tok, b.subnet)); r.Status != 200 {
			t.Fatalf("status %d: %d", i, r.Status)
		}
	}
	if r := e.do("GET", "/queue/status", nil, hdr(b.tok, b.subnet)); r.Status != 429 {
		t.Errorf("status flood: %d", r.Status)
	}
	// The status budget is separate from the queue one, and refills with time.
	if r := e.do("GET", "/queue/status", nil, hdr(a.tok, a.subnet)); r.Status != 200 {
		t.Errorf("a: %d", r.Status)
	}
	e.now = e.now.Add(time.Minute)
	if r := e.enterQueue(a, nil); r.Status != 200 {
		t.Errorf("refilled: %d", r.Status)
	}
}

func TestServerChoiceByLatencyAndDrain(t *testing.T) {
	e := queueEnv(t, nil)
	regSrv := func(name, region string) (string, string) {
		r := e.do("POST", "/servers/register", map[string]any{"name": name, "region": region, "url": "wss://" + name + ".example.com", "capacity": 5}, bearer(registerToken))
		if r.Status != 201 {
			t.Fatalf("%d %s", r.Status, r.Body)
		}
		j := r.json(t)
		id, key := j["server_id"].(string), j["key"].(string)
		if hb := e.do("POST", "/servers/heartbeat", map[string]any{"capacity": 5}, serverAuth(id, key)); hb.Status != 200 {
			t.Fatalf("hb %d %s", hb.Status, hb.Body)
		}
		return id, key
	}
	euID, euKey := regSrv("eu-1", "eu")
	usID, usKey := regSrv("us-1", "us")

	a, b := e.steamRacer(1), e.steamRacer(2)
	latFor := func(eu, us int) map[string]int { return map[string]int{"eu": eu, "us": us} }
	enter := func(r racer, l map[string]int) {
		if res := e.enterQueue(r, l); res.Status != 200 {
			t.Fatal(res.Status, string(res.Body))
		}
	}
	// a is close to eu (20) and far from us (180); b is close to us (30) and far from eu (170).
	// max over the group: eu = 170, us = 180 -> eu is the lowest maximum, even though us is closer for b.
	enter(a, latFor(20, 180))
	enter(b, latFor(170, 30))
	e.advance(31 * time.Second)
	e.confirm(a)
	e.confirm(b)
	e.advance(time.Second)
	mid := e.status(a)["match"].(map[string]any)["match_id"].(string)
	if ws := e.join(a, mid).json(t)["ws_url"]; ws != "wss://eu-1.example.com" {
		t.Fatalf("lowest max latency is eu: %v", ws)
	}
	// Settle it so the players are free.
	e.do("POST", "/matches/"+mid+"/result", map[string]any{"players": []map[string]any{{"player_id": a.id, "place": 1}, {"player_id": b.id, "place": 2}}}, serverAuth(euID, euKey))

	// Drain eu: the next heartbeat tells the server, and the match goes to us.
	if r := e.do("POST", "/admin/servers/"+euID+"/drain", map[string]bool{"drain": true}, bearer(adminToken)); r.Status != 200 {
		t.Fatal(r.Status, string(r.Body))
	}
	hb := e.do("POST", "/servers/heartbeat", map[string]any{"capacity": 5, "active_matches": 0}, serverAuth(euID, euKey)).json(t)
	if hb["drain"] != true || hb["capacity"].(float64) != 5 || hb["free"].(float64) != 5 || hb["ok"] != true {
		t.Fatalf("heartbeat reply %v", hb)
	}
	if hb2 := e.do("POST", "/servers/heartbeat", map[string]any{"capacity": 5}, serverAuth(usID, usKey)).json(t); hb2["drain"] != false {
		t.Errorf("us is not draining: %v", hb2)
	}
	mid = e.startMatch(a, b)
	if ws := e.join(a, mid).json(t)["ws_url"]; ws != "wss://us-1.example.com" {
		t.Fatalf("eu drained: %v", ws)
	}
	srvs := e.do("GET", "/admin/servers", nil, bearer(adminToken)).json(t)["servers"].([]any)
	if len(srvs) != 2 {
		t.Fatalf("%v", srvs)
	}
	for _, s := range srvs {
		sm := s.(map[string]any)
		if sm["name"] == "eu-1" && (sm["draining"] != true || sm["drain_requested"] != true) {
			t.Errorf("%v", sm)
		}
		if sm["name"] == "us-1" && sm["open_matches"].(float64) != 1 {
			t.Errorf("%v", sm)
		}
	}
	// Lifting the drain.
	e.do("POST", "/admin/servers/"+euID+"/drain", map[string]bool{"drain": false}, bearer(adminToken))
	if hb := e.do("POST", "/servers/heartbeat", map[string]any{"capacity": 5}, serverAuth(euID, euKey)).json(t); hb["drain"] != false {
		t.Errorf("%v", hb)
	}
	if r := e.do("POST", "/admin/servers/999/drain", nil, bearer(adminToken)); r.Status != 404 {
		t.Errorf("%d", r.Status)
	}
	if r := e.do("POST", "/admin/servers/"+euID+"/drain", nil, nil); r.Status != 401 {
		t.Errorf("%d", r.Status)
	}
}

func TestNoServerMeansTheQueueKeepsWaiting(t *testing.T) {
	e := queueEnv(t, nil) // no game server registered
	a, b := e.guestRacer(1), e.guestRacer(2)
	e.enterQueue(a, nil)
	e.enterQueue(b, nil)
	e.advance(45 * time.Second)
	if st := e.status(a); st["state"] != "waiting" || st["wait_s"].(float64) != 45 || st["band_divisions"].(float64) != 5 {
		t.Fatalf("%v", st)
	}
	q := e.do("GET", "/admin/queue", nil, bearer(adminToken)).json(t)
	if len(q["queue"].([]any)) != 2 || q["params"].(map[string]any)["ready_seconds"].(float64) != 15 {
		t.Fatalf("%v", q)
	}
	// A server appears: the next pass finds the match.
	e.registerServer()
	e.advance(time.Second)
	if st := e.status(a); st["state"] != "found" {
		t.Fatalf("%v", st)
	}
	q = e.do("GET", "/admin/queue", nil, bearer(adminToken)).json(t)
	if len(q["pending"].([]any)) != 1 {
		t.Fatalf("%v", q)
	}
}

func TestAdminUnbanAndReadyTimeoutOverHTTP(t *testing.T) {
	e := queueEnv(t, nil)
	e.registerServer()
	a, b, c := e.steamRacer(1), e.steamRacer(2), e.steamRacer(3)
	for _, r := range []racer{a, b, c} {
		e.enterQueue(r, nil)
	}
	e.advance(31 * time.Second)
	e.confirm(a)
	e.confirm(b)
	e.advance(14 * time.Second) // c is still silent, 1 s before the deadline
	if st := e.status(c); st["state"] != "found" {
		t.Fatalf("%v", st)
	}
	e.advance(time.Second)
	if st := e.status(c); st["state"] != "idle" {
		t.Fatalf("late player is dropped: %v", st)
	}
	st := e.status(a)
	if st["state"] != "starting" || st["players_found"].(float64) != 2 {
		t.Fatalf("starts with the two who confirmed: %v", st)
	}
	// Ban / unban over HTTP.
	if r := e.do("POST", "/admin/players/"+c.id+"/ban", map[string]string{"reason": "x"}, bearer(adminToken)); r.Status != 200 {
		t.Fatal(r.Status)
	}
	if r := e.do("GET", "/queue/status", nil, hdr(c.tok, c.subnet)); r.Status != 401 {
		t.Errorf("banned: %d", r.Status)
	}
	if r := e.do("POST", "/admin/players/"+c.id+"/unban", nil, bearer(adminToken)); r.Status != 200 {
		t.Fatal(r.Status)
	}
	if r := e.do("POST", "/auth/steam", map[string]string{"ticket": "ok-765611980000" + "00003"}, nil); r.Status != 200 {
		t.Errorf("login after unban: %d %s", r.Status, r.Body)
	}
	if r := e.do("POST", "/admin/players/"+c.id+"/unban", nil, nil); r.Status != 401 {
		t.Errorf("%d", r.Status)
	}
}
