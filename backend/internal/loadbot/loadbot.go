// Package loadbot drives many fake guests through the matchmaking API: guest login, queue, confirm, join. It can also
// play the game server (register, heartbeat, post results) so the whole path to settlement is exercised. Used by
// cmd/loadbot against a running API, and by the integration test.
package loadbot

import (
	"context"
	"errors"
	"fmt"
	"math/rand"
	"sort"
	"strconv"
	"sync"
	"time"

	"fuelrivals/backend/internal/apiclient"
	"fuelrivals/backend/internal/ticket"
)

// Config says what to run.
type Config struct {
	BaseURL   string        // API base, e.g. http://localhost:8080
	Players   int           // fake guests
	Region    string        // region name used for the measured latency
	LatencyMS int           // the latency reported to that region
	Ramp      time.Duration // arrivals are spread over this time
	Poll      time.Duration // status polling interval (the real client polls about once a second)
	Timeout   time.Duration // give up after this long
	Seed      int64

	// Playing the game server (optional): needs both tokens.
	SimulateServer bool
	RegisterToken  string
	AdminToken     string
	ServerName     string
	ServerURL      string // wss:// or ws://localhost
	Logf           func(format string, args ...any)
}

// Report is the outcome.
type Report struct {
	Players        int            `json:"players"`
	Joined         int            `json:"joined"`
	Failed         int            `json:"failed"`
	Errors         map[string]int `json:"errors,omitempty"`
	Requeues       int            `json:"requeues"`
	WaitToFoundP50 float64        `json:"wait_to_found_p50_s"`
	WaitToFoundP95 float64        `json:"wait_to_found_p95_s"`
	WaitToJoinP50  float64        `json:"wait_to_join_p50_s"`
	WaitToJoinP95  float64        `json:"wait_to_join_p95_s"`
	Matches        int            `json:"matches"`
	GroupSizes     map[int]int    `json:"group_sizes"`
	BotFilled      int            `json:"bot_filled_matches"`
	Settled        int            `json:"settled_matches"`
	Requests       int            `json:"requests"`
	RateLimited    int            `json:"rate_limited"`
}

type bot struct {
	id       string
	token    string
	matchID  string
	toFound  time.Duration
	toJoin   time.Duration
	requeues int
	err      error
}

type runner struct {
	cfg Config
	c   *apiclient.Client
	mu  sync.Mutex
	req int
	rl  int
}

func (r *runner) logf(format string, args ...any) {
	if r.cfg.Logf != nil {
		r.cfg.Logf(format, args...)
	}
}

func (r *runner) do(ctx context.Context, method, path, token string, headers map[string]string, body any) (*apiclient.Response, error) {
	for {
		res, err := r.c.Do(ctx, method, path, token, headers, body)
		r.mu.Lock()
		r.req++
		if err == nil && res.Status == 429 {
			r.rl++
		}
		r.mu.Unlock()
		if err != nil || res.Status != 429 {
			return res, err
		}
		wait := 2 * time.Second
		if s, perr := strconv.Atoi(res.Header.Get("Retry-After")); perr == nil && s > 0 {
			wait = time.Duration(s) * time.Second
		}
		if wait > 10*time.Second {
			return res, nil // a long limit (guests per hour): report it instead of waiting
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(wait):
		}
	}
}

func (r *runner) runBot(ctx context.Context, b *bot, rng *rand.Rand) {
	fail := func(format string, args ...any) { b.err = fmt.Errorf(format, args...) }
	res, err := r.do(ctx, "POST", "/auth/guest", "", nil, nil)
	if err != nil {
		fail("guest: %v", err)
		return
	}
	if !res.OK() {
		fail("guest: %v", res.Err())
		return
	}
	var sess struct {
		Token   string `json:"token"`
		Profile struct {
			PlayerID string `json:"player_id"`
		} `json:"profile"`
	}
	if err := res.JSON(&sess); err != nil || sess.Token == "" {
		fail("guest: bad answer")
		return
	}
	b.token, b.id = sess.Token, sess.Profile.PlayerID

	enter := func() error {
		res, err := r.do(ctx, "POST", "/queue", b.token, nil, map[string]any{"latencies": map[string]int{r.cfg.Region: r.cfg.LatencyMS + rng.Intn(20)}})
		if err != nil {
			return err
		}
		if !res.OK() {
			return res.Err()
		}
		return nil
	}
	start := time.Now()
	if err := enter(); err != nil {
		fail("queue: %v", err)
		return
	}
	confirmed := ""
	found := false
	for {
		select {
		case <-ctx.Done():
			fail("timeout waiting for a match")
			return
		case <-time.After(r.cfg.Poll + time.Duration(rng.Int63n(int64(r.cfg.Poll)/4+1))):
		}
		res, err := r.do(ctx, "GET", "/queue/status", b.token, nil, nil)
		if err != nil {
			fail("status: %v", err)
			return
		}
		if !res.OK() {
			fail("status: %v", res.Err())
			return
		}
		var st struct {
			State string `json:"state"`
			Match *struct {
				MatchID string `json:"match_id"`
			} `json:"match"`
		}
		if err := res.JSON(&st); err != nil {
			fail("status: bad answer")
			return
		}
		switch st.State {
		case "waiting", "ready":
		case "found":
			if !found {
				found, b.toFound = true, time.Since(start)
			}
			if st.Match != nil && confirmed != st.Match.MatchID {
				cr, err := r.do(ctx, "POST", "/queue/ready", b.token, nil, map[string]string{"match_id": st.Match.MatchID})
				if err != nil {
					fail("ready: %v", err)
					return
				}
				if cr.OK() {
					confirmed = st.Match.MatchID
				}
			}
		case "starting":
			if st.Match == nil {
				fail("starting without a match")
				return
			}
			b.matchID = st.Match.MatchID
			jr, err := r.do(ctx, "GET", "/match/"+b.matchID+"/join", b.token, nil, nil)
			if err != nil {
				fail("join: %v", err)
				return
			}
			if !jr.OK() {
				fail("join: %v", jr.Err())
				return
			}
			var j struct {
				WS     string `json:"ws_url"`
				Ticket string `json:"ticket"`
			}
			if err := jr.JSON(&j); err != nil || j.WS == "" || j.Ticket == "" {
				fail("join: bad answer")
				return
			}
			tk, _, _, err := ticket.Parse(j.Ticket)
			if err != nil || tk.MatchID != b.matchID || tk.PlayerID != b.id {
				fail("join: the ticket does not describe this seat (%v)", err)
				return
			}
			b.toJoin = time.Since(start)
			return
		case "idle":
			// Dropped (a ready-check without us, or a failed start): queue again.
			if found {
				found, confirmed = false, ""
			}
			b.requeues++
			if err := enter(); err != nil {
				fail("requeue: %v", err)
				return
			}
		}
	}
}

// Run starts the bots and, when asked, the simulated game server, and returns when every bot finished or Timeout passed.
func Run(ctx context.Context, cfg Config) (Report, error) {
	if cfg.Players < 1 {
		return Report{}, errors.New("loadbot: Players must be at least 1")
	}
	if cfg.Region == "" {
		cfg.Region = "eu"
	}
	if cfg.Poll <= 0 {
		cfg.Poll = time.Second
	}
	if cfg.Timeout <= 0 {
		cfg.Timeout = 3 * time.Minute
	}
	if cfg.LatencyMS <= 0 {
		cfg.LatencyMS = 40
	}
	r := &runner{cfg: cfg, c: apiclient.New(cfg.BaseURL)}
	ctx, cancel := context.WithTimeout(ctx, cfg.Timeout)
	defer cancel()

	var sim *gameServer
	if cfg.SimulateServer {
		var err error
		if sim, err = r.startServer(ctx); err != nil {
			return Report{}, err
		}
	}
	rng := rand.New(rand.NewSource(cfg.Seed + 1))
	bots := make([]*bot, cfg.Players)
	var wg sync.WaitGroup
	for i := range bots {
		bots[i] = &bot{}
		delay := time.Duration(0)
		if cfg.Ramp > 0 {
			delay = time.Duration(rng.Int63n(int64(cfg.Ramp)))
		}
		seed := rng.Int63()
		wg.Add(1)
		go func(b *bot, delay time.Duration, seed int64) {
			defer wg.Done()
			select {
			case <-ctx.Done():
				b.err = errors.New("timeout before starting")
				return
			case <-time.After(delay):
			}
			r.runBot(ctx, b, rand.New(rand.NewSource(seed)))
		}(bots[i], delay, seed)
	}
	wg.Wait()

	rep := Report{Players: cfg.Players, Errors: map[string]int{}, GroupSizes: map[int]int{}}
	var found, joined []float64
	perMatch := map[string]int{}
	for _, b := range bots {
		rep.Requeues += b.requeues
		if b.err != nil {
			rep.Failed++
			rep.Errors[b.err.Error()]++
			continue
		}
		rep.Joined++
		found = append(found, b.toFound.Seconds())
		joined = append(joined, b.toJoin.Seconds())
		perMatch[b.matchID]++
	}
	for _, n := range perMatch {
		rep.Matches++
		rep.GroupSizes[n]++
		if n < 6 {
			rep.BotFilled++
		}
	}
	rep.WaitToFoundP50, rep.WaitToFoundP95 = percentile(found, 50), percentile(found, 95)
	rep.WaitToJoinP50, rep.WaitToJoinP95 = percentile(joined, 50), percentile(joined, 95)
	if sim != nil {
		// Let the simulated server settle what is left.
		settleCtx, stop := context.WithTimeout(context.Background(), 15*time.Second)
		sim.drain(settleCtx, rep.Matches)
		stop()
		rep.Settled = sim.settledCount()
	}
	r.mu.Lock()
	rep.Requests, rep.RateLimited = r.req, r.rl
	r.mu.Unlock()
	return rep, nil
}

func percentile(v []float64, p int) float64 {
	if len(v) == 0 {
		return 0
	}
	s := append([]float64(nil), v...)
	sort.Float64s(s)
	i := (len(s)*p + 99) / 100
	if i < 1 {
		i = 1
	}
	if i > len(s) {
		i = len(s)
	}
	return s[i-1]
}
