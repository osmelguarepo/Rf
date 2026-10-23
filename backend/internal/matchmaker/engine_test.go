package matchmaker

import (
	"context"
	"errors"
	"testing"
	"time"

	"fuelrivals/backend/internal/store"
	"fuelrivals/backend/internal/telemetry"
)

// fakeBackend is an in-memory Backend.
type fakeBackend struct {
	servers   []store.ServerState
	nextID    int64
	assigned  []store.AssignRequest
	assignErr error
	open      map[int64]bool
	penalties map[int64]store.Penalty
}

func newFake() *fakeBackend {
	return &fakeBackend{nextID: 100, open: map[int64]bool{}, penalties: map[int64]store.Penalty{},
		servers: []store.ServerState{srvState(1, "eu", 10)}}
}

func srvState(id int64, region string, capacity int) store.ServerState {
	return store.ServerState{Server: store.Server{ID: id, Name: "s", Region: region, URL: "wss://x", Capacity: capacity}, LeaseAlive: true}
}

func (f *fakeBackend) ListServers(context.Context) ([]store.ServerState, error) {
	return append([]store.ServerState(nil), f.servers...), nil
}
func (f *fakeBackend) ReserveMatchID(context.Context) (int64, error) {
	f.nextID++
	return f.nextID, nil
}
func (f *fakeBackend) AssignMatch(_ context.Context, r store.AssignRequest) (store.Assignment, error) {
	if f.assignErr != nil {
		return store.Assignment{}, f.assignErr
	}
	f.assigned = append(f.assigned, r)
	a := store.Assignment{MatchID: r.MatchID, Bots: 6 - len(r.Seats)}
	for _, s := range r.Seats {
		a.Seats = append(a.Seats, store.AssignedSeat{PlayerID: s.PlayerID, Seat: s.Seat})
		f.open[s.PlayerID] = true
	}
	return a, nil
}
func (f *fakeBackend) PlayerOpenMatch(_ context.Context, id int64) (int64, bool, error) {
	return 0, f.open[id], nil
}
func (f *fakeBackend) LoadPenalty(_ context.Context, id int64) (store.Penalty, error) {
	return f.penalties[id], nil
}
func (f *fakeBackend) SavePenalty(_ context.Context, id int64, p store.Penalty) error {
	f.penalties[id] = p
	return nil
}

type rig struct {
	t   *testing.T
	be  *fakeBackend
	e   *Engine
	now time.Time
	m   *telemetry.Registry
}

func newRig(t *testing.T) *rig {
	r := &rig{t: t, be: newFake(), now: t0, m: telemetry.New()}
	r.e = NewEngine(DefaultParams(), r.be, func() time.Time { return r.now }, nil, r.m)
	return r
}

func (r *rig) advance(d time.Duration) {
	r.now = r.now.Add(d)
	r.e.Tick(context.Background())
}

func (r *rig) enter(id int64, points int) {
	r.t.Helper()
	if _, err := r.e.Enter(context.Background(), EnterInput{PlayerID: id, Points: points, Latencies: map[string]int{"eu": 40}, IPPrefix: "p"}); err != nil {
		r.t.Fatalf("enter %d: %v", id, err)
	}
}

func (r *rig) state(id int64) string { return r.e.Status(id).State }

func (r *rig) matchOf(id int64) int64 {
	st := r.e.Status(id)
	if st.Match == nil {
		r.t.Fatalf("player %d has no match: %+v", id, st)
	}
	n := int64(0)
	for _, c := range st.Match.MatchID {
		n = n*10 + int64(c-'0')
	}
	return n
}

// fillToFound enters n players of one division and ticks until a match is found (they wait 30 s).
func (r *rig) found(n int) {
	for i := 1; i <= n; i++ {
		r.enter(int64(i), 500)
	}
	r.advance(30 * time.Second)
}

func TestReadyCheckAllConfirmStartsTheMatch(t *testing.T) {
	r := newRig(t)
	r.found(3)
	for i := int64(1); i <= 3; i++ {
		if r.state(i) != StateFound {
			t.Fatalf("player %d: %s", i, r.state(i))
		}
	}
	st := r.e.Status(1)
	if st.PlayersFound != 3 || st.Match.ReadyDeadlineUnix != r.now.Add(15*time.Second).Unix() {
		t.Fatalf("%+v", st)
	}
	mid := r.matchOf(1)
	if err := r.e.Confirm(1, mid+1); !errors.Is(err, ErrNoMatch) {
		t.Errorf("wrong match id: %v", err)
	}
	if err := r.e.Confirm(99, mid); !errors.Is(err, ErrNoMatch) {
		t.Errorf("stranger: %v", err)
	}
	for _, id := range []int64{1, 2} {
		if err := r.e.Confirm(id, mid); err != nil {
			t.Fatal(err)
		}
		if err := r.e.Confirm(id, mid); err != nil { // idempotent
			t.Fatal(err)
		}
	}
	r.advance(time.Second)
	if r.state(1) != StateReady || r.state(3) != StateFound || len(r.be.assigned) != 0 {
		t.Fatalf("two of three confirmed: %s %s", r.state(1), r.state(3))
	}
	_ = r.e.Confirm(3, mid)
	r.advance(time.Second)
	if len(r.be.assigned) != 1 {
		t.Fatal("all confirmed: the match should start on the next tick")
	}
	a := r.be.assigned[0]
	if a.MatchID != mid || a.ServerID != 1 || len(a.Seats) != 3 {
		t.Fatalf("%+v", a)
	}
	for i := int64(1); i <= 3; i++ {
		st := r.e.Status(i)
		if st.State != StateStarting || st.Match == nil || st.Match.MatchID != r.e.Status(1).Match.MatchID {
			t.Fatalf("player %d: %+v", i, st)
		}
	}
	if got := r.m.Counter("fr_matches_started_total", "filled", "bots"); got != 1 {
		t.Errorf("bot-filled matches: %v", got)
	}
	if got := r.m.Counter("fr_match_bots_total"); got != 3 {
		t.Errorf("bots: %v", got)
	}
	for _, stage := range []string{"queued", "found", "ready", "started"} {
		if got := r.m.Counter("fr_funnel_total", "stage", stage); got != 3 {
			t.Errorf("funnel %s = %v", stage, got)
		}
	}
	// Starting players cannot queue again while the match is open.
	if _, err := r.e.Enter(context.Background(), EnterInput{PlayerID: 1}); !errors.Is(err, ErrBusy) {
		t.Errorf("enter while in a match: %v", err)
	}
	// Starting lasts until they fetch the ticket.
	r.e.ForgetStarted(1)
	if r.state(1) != StateIdle {
		t.Error("forget")
	}
}

func TestReadyCheckTimeoutDropsTheLateAndStartsWithTwoOrMore(t *testing.T) {
	r := newRig(t)
	r.found(3)
	mid := r.matchOf(1)
	_ = r.e.Confirm(1, mid)
	_ = r.e.Confirm(2, mid)
	r.advance(14 * time.Second)
	if len(r.be.assigned) != 0 {
		t.Fatal("before the deadline")
	}
	r.advance(time.Second)
	if len(r.be.assigned) != 1 || len(r.be.assigned[0].Seats) != 2 {
		t.Fatalf("starts with those who confirmed: %+v", r.be.assigned)
	}
	if r.state(3) != StateIdle {
		t.Errorf("the late player is out: %s", r.state(3))
	}
	if r.be.penalties[3].Strikes != 1 {
		t.Errorf("strike: %+v", r.be.penalties[3])
	}
	if r.m.Counter("fr_abandons_total", "kind", StrikeReadyTimeout) != 1 {
		t.Error("abandon counter")
	}
}

func TestReadyCheckWithOneConfirmedRequeuesWithPriority(t *testing.T) {
	r := newRig(t)
	r.found(2)
	mid := r.matchOf(1)
	_ = r.e.Confirm(1, mid)
	r.advance(15 * time.Second)
	if len(r.be.assigned) != 0 {
		t.Fatal("one confirmed human does not start a ready-checked match")
	}
	// The confirmed player goes back to the queue with priority; their original wait counts, so the solo rule applies
	// in the same pass (they have waited far longer than 30 s): a new ready-check with bots.
	if r.state(2) != StateIdle {
		t.Fatalf("2: %s", r.state(2))
	}
	st := r.e.Status(1)
	if st.State != StateFound || st.PlayersFound != 1 || r.matchOf(1) == mid {
		t.Fatalf("solo+bots after the earlier wait: %+v", st)
	}
	if _, pend := r.e.Snapshot(); len(pend) != 1 {
		t.Fatalf("%+v", pend)
	}
}

func TestDeclineDuringReadyCheck(t *testing.T) {
	r := newRig(t)
	r.found(3)
	mid := r.matchOf(1)
	r.e.Leave(context.Background(), 3) // declines
	if r.state(3) != StateIdle || r.be.penalties[3].Strikes != 1 {
		t.Fatalf("decliner: %s %+v", r.state(3), r.be.penalties[3])
	}
	// The other two go on and start as soon as they both confirm.
	_ = r.e.Confirm(1, mid)
	_ = r.e.Confirm(2, mid)
	r.advance(time.Second)
	if len(r.be.assigned) != 1 || len(r.be.assigned[0].Seats) != 2 {
		t.Fatalf("%+v", r.be.assigned)
	}

	// With one left, the match is cancelled and that player re-queues first.
	r2 := newRig(t)
	r2.found(2)
	r2.e.Leave(context.Background(), 2)
	if r2.state(1) != StateWaiting {
		t.Fatalf("remaining player: %s", r2.state(1))
	}
	q, pend := r2.e.Snapshot()
	if len(q) != 1 || !q[0].Priority || len(pend) != 0 {
		t.Fatalf("%+v %+v", q, pend)
	}
	// Cancelling from the queue is free.
	r2.e.Leave(context.Background(), 1)
	if r2.state(1) != StateIdle || r2.be.penalties[1].Strikes != 0 {
		t.Error("leaving the queue before a match is found carries no penalty")
	}
	if r2.m.Counter("fr_abandons_total", "kind", "queue_cancel") != 1 {
		t.Error("queue_cancel counter")
	}
}

func TestEveryoneTimesOut(t *testing.T) {
	r := newRig(t)
	r.found(2)
	r.advance(15 * time.Second)
	if len(r.be.assigned) != 0 || r.state(1) != StateIdle || r.state(2) != StateIdle {
		t.Fatal("nobody confirmed")
	}
	q, pend := r.e.Snapshot()
	if len(q) != 0 || len(pend) != 0 {
		t.Fatalf("%v %v", q, pend)
	}
}

func TestSoloGetsBotsAfterSoloWaitAndStaysUnrankedFlowThroughReadyCheck(t *testing.T) {
	r := newRig(t)
	r.enter(7, 500)
	r.advance(29 * time.Second)
	if r.state(7) != StateWaiting {
		t.Fatalf("%s", r.state(7))
	}
	st := r.e.Status(7)
	if st.WaitS != 29 || st.BandDivisions != 3 || st.PlayersFound != 1 {
		t.Fatalf("%+v", st)
	}
	r.advance(time.Second)
	if r.state(7) != StateFound {
		t.Fatalf("%s", r.state(7))
	}
	_ = r.e.Confirm(7, r.matchOf(7))
	r.advance(time.Second)
	if len(r.be.assigned) != 1 || len(r.be.assigned[0].Seats) != 1 || r.state(7) != StateStarting {
		t.Fatalf("%+v", r.be.assigned)
	}
	if r.m.Counter("fr_match_humans_total") != 1 || r.m.Counter("fr_match_bots_total") != 5 {
		t.Error("humans and bots are counted")
	}
}

func TestNoServerNoMatchAndDrainingServers(t *testing.T) {
	r := newRig(t)
	r.be.servers[0].Draining = true
	r.found(2)
	if r.state(1) != StateWaiting {
		t.Fatalf("no usable server: %s", r.state(1))
	}
	r.be.servers[0].Draining = false
	r.be.servers[0].DrainRequested = true
	r.advance(time.Second)
	if r.state(1) != StateWaiting {
		t.Fatal("drain requested by an operator")
	}
	r.be.servers[0].DrainRequested = false
	r.be.servers[0].LeaseAlive = false
	r.advance(time.Second)
	if r.state(1) != StateWaiting {
		t.Fatal("lease expired")
	}
	r.be.servers[0].LeaseAlive = true
	r.be.servers[0].OpenMatches = 10
	r.advance(time.Second)
	if r.state(1) != StateWaiting {
		t.Fatal("full")
	}
	r.be.servers[0].OpenMatches = 9
	r.advance(time.Second)
	if r.state(1) != StateFound {
		t.Fatal("one free slot")
	}
}

func TestCapacityIsReservedWhileMatchesAreWaitingForConfirmation(t *testing.T) {
	r := newRig(t)
	r.be.servers[0].Capacity = 1
	for i := 1; i <= 4; i++ {
		r.enter(int64(i), 500)
	}
	r.enter(5, 500)
	r.enter(6, 500)
	r.enter(7, 500)
	r.advance(30 * time.Second)
	found := 0
	for i := int64(1); i <= 7; i++ {
		if r.state(i) == StateFound {
			found++
		}
	}
	if found == 0 || found > 6 {
		t.Fatalf("one match only: %d players found", found)
	}
	_, pend := r.e.Snapshot()
	if len(pend) != 1 {
		t.Fatalf("a server with capacity 1 holds one pending match: %d", len(pend))
	}
}

func TestHighLatencyWaitsThenIsAcceptedAndFlagged(t *testing.T) {
	r := newRig(t)
	for i := int64(1); i <= 2; i++ {
		if _, err := r.e.Enter(context.Background(), EnterInput{PlayerID: i, Points: 500, Latencies: map[string]int{"eu": 400}}); err != nil {
			t.Fatal(err)
		}
	}
	r.advance(29 * time.Second)
	if r.state(1) != StateWaiting {
		t.Fatal("not before MaxWait")
	}
	r.advance(time.Second)
	if st := r.e.Status(1); st.State != StateFound || !st.HighLatency {
		t.Fatalf("%+v", st)
	}
	// A server that is close enough is taken at once.
	r2 := newRig(t)
	r2.be.servers = append(r2.be.servers, srvState(2, "us", 10))
	for i := int64(1); i <= 6; i++ {
		_, _ = r2.e.Enter(context.Background(), EnterInput{PlayerID: i, Points: 500, Latencies: map[string]int{"eu": 400, "us": 100}})
	}
	r2.advance(time.Second)
	st := r2.e.Status(1)
	if st.State != StateFound || st.HighLatency {
		t.Fatalf("%+v", st)
	}
	if _, pend := r2.e.Snapshot(); pend[0].ServerID != "2" {
		t.Errorf("lowest latency server: %v", pend[0].ServerID)
	}
}

func TestPenaltyQueueBansForRepeatLeavers(t *testing.T) {
	r := newRig(t)
	bg := context.Background()
	// Three declines in a day: the first two only warn, the third closes the queue for 5 minutes.
	for i := 0; i < 3; i++ {
		r.enter(1, 500)
		r.enter(2, 500)
		r.advance(30 * time.Second)
		if r.state(1) != StateFound {
			t.Fatalf("round %d: %s", i, r.state(1))
		}
		r.e.Leave(bg, 1) // player 1 declines the found match
		r.e.Leave(bg, 2) // player 2 (back in the queue) gives up
	}
	if r.be.penalties[1].Strikes != 3 {
		t.Fatalf("%+v", r.be.penalties[1])
	}
	_, err := r.e.Enter(bg, EnterInput{PlayerID: 1, Points: 500})
	var ban *BanError
	if !errors.As(err, &ban) || ban.Until.Sub(r.now) <= 0 || ban.Until.Sub(r.now) > 5*time.Minute {
		t.Fatalf("expected a ban of at most 5 minutes, got %v", err)
	}
	// Other players are not affected, and the ban ends.
	if _, err := r.e.Enter(bg, EnterInput{PlayerID: 2, Points: 500}); err != nil {
		t.Fatal(err)
	}
	r.now = r.now.Add(5*time.Minute + time.Second)
	if _, err := r.e.Enter(bg, EnterInput{PlayerID: 1, Points: 500}); err != nil {
		t.Fatalf("after the ban: %v", err)
	}
	// The counters survive a restart: a new engine over the same store still bans.
	r.be.penalties[9] = store.Penalty{Strikes: 5, LastAt: r.now, BannedUntil: r.now.Add(time.Hour)}
	e2 := NewEngine(DefaultParams(), r.be, func() time.Time { return r.now }, nil, telemetry.New())
	if _, err := e2.Enter(bg, EnterInput{PlayerID: 9}); !errors.As(err, &ban) {
		t.Fatalf("stored ban: %v", err)
	}
	// An admin lifting the ban clears the cache.
	r.be.penalties[9] = store.Penalty{}
	e2.ClearPenalty(9)
	if _, err := e2.Enter(bg, EnterInput{PlayerID: 9}); err != nil {
		t.Fatal(err)
	}
}

func TestEnterIsIdempotentAndBusyChecks(t *testing.T) {
	r := newRig(t)
	bg := context.Background()
	a, err := r.e.Enter(bg, EnterInput{PlayerID: 1, Points: 10})
	b, err2 := r.e.Enter(bg, EnterInput{PlayerID: 1, Points: 10})
	if err != nil || err2 != nil || a != b || a == "" {
		t.Fatalf("%q %q %v %v", a, b, err, err2)
	}
	r.be.open[2] = true
	if _, err := r.e.Enter(bg, EnterInput{PlayerID: 2}); !errors.Is(err, ErrBusy) {
		t.Errorf("open match: %v", err)
	}
	// In a ready-check: busy.
	r.enter(3, 500)
	r.found(0)
	r.advance(30 * time.Second)
	if r.state(1) == StateFound {
		if _, err := r.e.Enter(bg, EnterInput{PlayerID: 1}); !errors.Is(err, ErrBusy) {
			t.Errorf("ready-check: %v", err)
		}
	}
	// Latencies are cleaned: negative and absurd values do not break ordering.
	got := cleanLatencies(map[string]int{"eu": -5, "us": 99999, "": 3, "ap": 80})
	if len(got) != 2 || got["us"] != 5000 || got["ap"] != 80 {
		t.Errorf("%v", got)
	}
}

func TestAssignFailureRequeuesAndBusyPlayersAreDropped(t *testing.T) {
	r := newRig(t)
	r.found(3)
	mid := r.matchOf(1)
	for i := int64(1); i <= 3; i++ {
		_ = r.e.Confirm(i, mid)
	}
	r.be.assignErr = store.ErrDraining
	r.advance(time.Second)
	// A failed assignment puts everyone back, and they are grouped again in the same pass under a new match id.
	if r.state(1) != StateFound || r.matchOf(1) == mid || len(r.be.assigned) != 0 {
		t.Fatalf("a failed assignment puts everyone back: %s", r.state(1))
	}
	if q, pend := r.e.Snapshot(); len(q) != 0 || len(pend) != 1 || len(pend[0].Confirmed) != 0 {
		t.Fatalf("%+v %+v", q, pend)
	}
	// Player 2 turns out to be in another match: dropped, the others are grouped again.
	mid = r.matchOf(1)
	for i := int64(1); i <= 3; i++ {
		_ = r.e.Confirm(i, mid)
	}
	r.be.assignErr = store.ErrBusy
	r.be.open[2] = true
	r.advance(time.Second)
	if r.state(2) != StateIdle || r.state(1) != StateFound || r.state(3) != StateFound || r.e.Status(1).PlayersFound != 2 {
		t.Fatalf("%s %s %s", r.state(1), r.state(2), r.state(3))
	}
	// And once the assignment works, it starts with the two.
	r.be.assignErr = nil
	mid = r.matchOf(1)
	_ = r.e.Confirm(1, mid)
	_ = r.e.Confirm(3, mid)
	r.advance(time.Second)
	if len(r.be.assigned) != 1 || len(r.be.assigned[0].Seats) != 2 {
		t.Fatalf("%+v", r.be.assigned)
	}
}
