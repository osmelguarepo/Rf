package matchmaker

import (
	"fmt"
	"math/rand"
	"testing"
	"time"

	"fuelrivals/backend/internal/store"
)

var t0 = time.Date(2026, 10, 23, 12, 0, 0, 0, time.UTC)

// pointsOfDivision is a point total inside each division (starts 0, 300, 700, 1200, 1800).
var pointsOfDivision = []int{100, 400, 900, 1400, 2000}

func tk(id int64, points int, entered time.Time) *Ticket {
	return &Ticket{PlayerID: id, Points: points, EnteredAt: entered, IPPrefix: fmt.Sprintf("10.0.%d", id)}
}

func TestBandWidensEveryStepUpToAnyDivision(t *testing.T) {
	p := DefaultParams()
	for _, c := range []struct {
		wait time.Duration
		band int
	}{{0, 1}, {9 * time.Second, 1}, {10 * time.Second, 2}, {19 * time.Second, 2}, {20 * time.Second, 3}, {29 * time.Second, 3},
		{30 * time.Second, AnyBand}, {10 * time.Minute, AnyBand}, {-time.Second, 1}} {
		if got := p.Band(c.wait); got != c.band {
			t.Errorf("Band(%v) = %d, want %d", c.wait, got, c.band)
		}
	}
}

// With an injectable clock the compatibility of two tickets 3 divisions apart appears when the newer one has waited 20 s.
func TestCompatibilityWidensWithTheClock(t *testing.T) {
	p := DefaultParams()
	a := tk(1, pointsOfDivision[0], t0)
	b := tk(2, pointsOfDivision[3], t0)
	for _, c := range []struct {
		at time.Duration
		ok bool
	}{{0, false}, {9 * time.Second, false}, {10 * time.Second, false}, {19 * time.Second, false}, {20 * time.Second, true}, {40 * time.Second, true}} {
		if got := p.Compatible(a, b, t0.Add(c.at)); got != c.ok {
			t.Errorf("after %v: compatible = %v, want %v", c.at, got, c.ok)
		}
	}
	// The band follows the NEWER ticket: an old ticket does not drag a fresh one into a far division.
	late := tk(3, pointsOfDivision[4], t0.Add(100*time.Second))
	if p.Compatible(a, late, t0.Add(101*time.Second)) {
		t.Error("a ticket that just arrived must not be compatible with a division 4 away")
	}
	// Different simulation hashes never mix.
	a.SimHash, b.SimHash = "x", "y"
	b.Points = a.Points
	if p.Compatible(a, b, t0) {
		t.Error("different sim hashes")
	}
}

func TestOneHumanGetsBotsAfterSoloWait(t *testing.T) {
	p := DefaultParams()
	q := []*Ticket{tk(1, 500, t0)}
	if g := FormGroups(t0.Add(29*time.Second), q, p, nil); len(g) != 0 {
		t.Fatalf("29 s: %v", g)
	}
	g := FormGroups(t0.Add(30*time.Second), q, p, nil)
	if len(g) != 1 || g[0].Reason != "solo" || len(g[0].Tickets) != 1 || g[0].Bots() != 5 {
		t.Fatalf("30 s: %+v", g)
	}
	p.SoloWait = 5 * time.Second
	if g := FormGroups(t0.Add(5*time.Second), q, p, nil); len(g) != 1 {
		t.Error("QUEUE_SOLO_WAIT is a parameter")
	}
}

func TestTwoHumansLaunchWhenTheOldestWaitedMaxWait(t *testing.T) {
	p := DefaultParams()
	q := []*Ticket{tk(1, 500, t0), tk(2, 520, t0.Add(3*time.Second))}
	if g := FormGroups(t0.Add(29*time.Second), q, p, nil); len(g) != 0 {
		t.Fatalf("a group of 2 must wait for MaxWait: %v", g)
	}
	g := FormGroups(t0.Add(30*time.Second), q, p, nil)
	if len(g) != 1 || g[0].Reason != "timeout" || len(g[0].Tickets) != 2 || g[0].Bots() != 4 {
		t.Fatalf("%+v", g)
	}
	// Far apart (division 0 and 4): not together while the newer one has a narrow band.
	far := []*Ticket{tk(1, 100, t0), tk(2, 2000, t0.Add(25*time.Second))}
	if g := FormGroups(t0.Add(40*time.Second), far, p, nil); len(g) != 1 || len(g[0].Tickets) != 1 {
		t.Fatalf("the old one goes solo, the new one waits: %+v", g)
	}
	if g := FormGroups(t0.Add(56*time.Second), far, p, nil); len(g) != 1 || len(g[0].Tickets) != 2 {
		t.Fatalf("once the newer waited 30 s any division matches: %+v", g)
	}
}

func TestFiveWaitAndSixLaunchAtOnce(t *testing.T) {
	p := DefaultParams()
	var q []*Ticket
	for i := int64(1); i <= 5; i++ {
		q = append(q, tk(i, 500+int(i), t0))
	}
	if g := FormGroups(t0.Add(10*time.Second), q, p, nil); len(g) != 0 {
		t.Fatalf("five must wait: %v", g)
	}
	q = append(q, tk(6, 505, t0.Add(10*time.Second)))
	g := FormGroups(t0.Add(10*time.Second), q, p, nil)
	if len(g) != 1 || g[0].Reason != "full" || len(g[0].Tickets) != 6 || g[0].Bots() != 0 {
		t.Fatalf("%+v", g)
	}
	// A seventh stays for the next group.
	q = append(q, tk(7, 505, t0.Add(10*time.Second)))
	g = FormGroups(t0.Add(10*time.Second), q, p, nil)
	if len(g) != 1 || len(g[0].Tickets) != 6 {
		t.Fatalf("%+v", g)
	}
}

func TestRequeuedPriorityGoesFirst(t *testing.T) {
	p := DefaultParams()
	old := tk(1, 500, t0)
	pri := tk(2, 500, t0.Add(20*time.Second))
	pri.Priority = true
	var q []*Ticket
	q = append(q, old, pri)
	for i := int64(10); i < 15; i++ {
		q = append(q, tk(i, 500, t0.Add(20*time.Second)))
	}
	g := FormGroups(t0.Add(21*time.Second), q, p, nil)
	if len(g) != 1 || len(g[0].Tickets) != 6 || g[0].Tickets[0] != pri {
		t.Fatalf("the re-queued ticket anchors the group: %+v", g)
	}
}

func TestAcceptRefusalLeavesTicketsForOtherGroups(t *testing.T) {
	p := DefaultParams()
	var q []*Ticket
	for i := int64(1); i <= 12; i++ {
		q = append(q, tk(i, 500, t0))
	}
	calls := 0
	g := FormGroups(t0, q, p, func(g *Group) bool { calls++; return calls > 1 })
	if len(g) != 2 || calls != 3 {
		t.Fatalf("the first group was refused, the next two taken: %d groups, %d calls", len(g), calls)
	}
	g = FormGroups(t0, q, p, func(*Group) bool { return false })
	if len(g) != 0 {
		t.Fatal("nothing accepted")
	}
}

// run advances a queue second by second, adding the arrivals, and checks the rules after every pass.
type sim struct {
	t        *testing.T
	p        Params
	queue    []*Ticket
	groups   [][]*Ticket
	launched map[int64]int // ticket -> times launched
	at       map[int64]time.Duration
}

func (s *sim) step(now time.Time) {
	groups := FormGroups(now, s.queue, s.p, nil)
	taken := map[*Ticket]bool{}
	for _, g := range groups {
		if len(g.Tickets) < 1 || len(g.Tickets) > MaxField {
			s.t.Fatalf("group of %d", len(g.Tickets))
		}
		if len(g.Tickets) == 1 && g.Reason != "solo" {
			s.t.Fatalf("single ticket group with reason %s", g.Reason)
		}
		for _, tk := range g.Tickets {
			s.launched[tk.PlayerID]++
			s.at[tk.PlayerID] = tk.Wait(now)
			taken[tk] = true
		}
		s.groups = append(s.groups, g.Tickets)
	}
	var rest []*Ticket
	for _, tk := range s.queue {
		if !taken[tk] {
			rest = append(rest, tk)
		}
	}
	s.queue = rest
	// Nobody waits past MaxWait while another waiting ticket is compatible with them.
	for _, a := range s.queue {
		if a.Wait(now) < s.p.MaxWait {
			continue
		}
		for _, b := range s.queue {
			if a != b && s.p.Compatible(a, b, now) {
				s.t.Fatalf("ticket %d waited %v with ticket %d compatible and unmatched", a.PlayerID, a.Wait(now), b.PlayerID)
			}
		}
	}
}

func runSim(t *testing.T, n int, spread time.Duration, seed int64, p Params) *sim {
	t.Helper()
	rng := rand.New(rand.NewSource(seed))
	s := &sim{t: t, p: p, launched: map[int64]int{}, at: map[int64]time.Duration{}}
	arrivals := make([]time.Duration, n)
	pts := make([]int, n)
	for i := range arrivals {
		if spread > 0 {
			arrivals[i] = time.Duration(rng.Int63n(int64(spread)))
		}
		pts[i] = rng.Intn(2400)
	}
	next := 0
	order := make([]int, n)
	for i := range order {
		order[i] = i
	}
	// sort indexes by arrival
	for i := 1; i < n; i++ {
		for j := i; j > 0 && arrivals[order[j]] < arrivals[order[j-1]]; j-- {
			order[j], order[j-1] = order[j-1], order[j]
		}
	}
	for sec := 0; sec <= int((spread+5*time.Minute)/time.Second); sec++ {
		now := t0.Add(time.Duration(sec) * time.Second)
		for next < n && arrivals[order[next]] <= time.Duration(sec)*time.Second {
			i := order[next]
			s.queue = append(s.queue, tk(int64(i+1), pts[i], t0.Add(arrivals[i])))
			next++
		}
		s.step(now)
		if next == n && len(s.queue) == 0 {
			break
		}
	}
	return s
}

func (s *sim) check(n int) {
	s.t.Helper()
	if len(s.queue) != 0 {
		s.t.Fatalf("%d tickets never matched", len(s.queue))
	}
	if len(s.launched) != n {
		s.t.Fatalf("%d of %d players launched", len(s.launched), n)
	}
	for id, times := range s.launched {
		if times != 1 {
			s.t.Fatalf("player %d is in %d groups", id, times)
		}
	}
	for id, w := range s.at {
		// Nobody is launched later than SoloWait/MaxWait plus the step; the longest legitimate case is a lone ticket.
		if w > s.p.MaxWait+s.p.SoloWait+2*time.Second {
			s.t.Errorf("player %d waited %v", id, w)
		}
	}
}

func TestSyntheticQueues(t *testing.T) {
	p := DefaultParams()
	for _, n := range []int{1, 2, 5, 30, 100} {
		t.Run(fmt.Sprintf("%d players", n), func(t *testing.T) {
			for seed := int64(1); seed <= 5; seed++ {
				s := runSim(t, n, 40*time.Second, seed, p)
				s.check(n)
				humans := 0
				for _, g := range s.groups {
					if len(g) > MaxField {
						t.Fatalf("group of %d", len(g))
					}
					humans += len(g)
				}
				if humans != n {
					t.Fatalf("%d humans in groups, want %d", humans, n)
				}
			}
		})
	}
}

func TestHundredPlayersFormGroupsOfTwoToSixWithoutRepeats(t *testing.T) {
	p := DefaultParams()
	s := runSim(t, 100, 60*time.Second, 42, p)
	s.check(100)
	sizes := map[int]int{}
	seen := map[int64]bool{}
	solos := 0
	for _, g := range s.groups {
		sizes[len(g)]++
		if len(g) == 1 {
			solos++
		}
		for _, tk := range g {
			if seen[tk.PlayerID] {
				t.Fatalf("player %d repeated", tk.PlayerID)
			}
			seen[tk.PlayerID] = true
		}
	}
	if len(seen) != 100 {
		t.Fatalf("%d players grouped", len(seen))
	}
	if sizes[6] == 0 {
		t.Errorf("a busy queue must produce full groups: %v", sizes)
	}
	if solos > 3 {
		t.Errorf("too many lone players in a busy queue: %d (%v)", solos, sizes)
	}
	t.Logf("group sizes: %v", sizes)
}

func TestSubnetMatesAreSpreadWhenPossible(t *testing.T) {
	p := DefaultParams()
	a := tk(1, 500, t0)
	b := tk(2, 500, t0)
	c := tk(3, 500, t0)
	a.IPPrefix, b.IPPrefix, c.IPPrefix = "1.1.1", "1.1.1", "2.2.2"
	var q = []*Ticket{a, b, c}
	for i := int64(4); i <= 6; i++ {
		x := tk(i, 500, t0)
		x.IPPrefix = fmt.Sprintf("9.9.%d", i)
		q = append(q, x)
	}
	// 6 tickets: everyone is in the group anyway. With 7, the subnet mate of the anchor is the one left out.
	x7 := tk(7, 500, t0)
	x7.IPPrefix = "7.7.7"
	q = append(q, x7)
	g := FormGroups(t0, q, p, nil)
	if len(g) != 1 || len(g[0].Tickets) != 6 {
		t.Fatalf("%+v", g)
	}
	for _, m := range g[0].Tickets {
		if m == b {
			t.Error("the subnet mate of the anchor should wait for the next group when someone else fits")
		}
	}
}

func srv(id int64, region string, capacity, open int) ServerInfo {
	return ServerInfo{ID: id, Name: fmt.Sprintf("s%d", id), Region: region, Capacity: capacity, Open: open, Alive: true}
}

func lat(m map[string]int) *Ticket { return &Ticket{Latencies: m} }

func TestServerChoiceLowestMaxLatency(t *testing.T) {
	servers := []ServerInfo{srv(1, "eu", 10, 0), srv(2, "us", 10, 0), srv(3, "ap", 10, 0)}
	group := []*Ticket{lat(map[string]int{"eu": 30, "us": 120, "ap": 300}), lat(map[string]int{"eu": 200, "us": 90, "ap": 280})}
	// eu: max 200, us: max 120, ap: max 300
	i, worst, ok := ChooseServer(servers, group)
	if !ok || servers[i].ID != 2 || worst != 120 {
		t.Fatalf("got %d %d %v", i, worst, ok)
	}
	// Not the lowest sum or average: eu would win on the first player alone.
	servers[1].Draining = true
	i, worst, _ = ChooseServer(servers, group)
	if servers[i].ID != 1 || worst != 200 {
		t.Fatalf("drained us: %d %d", servers[i].ID, worst)
	}
	// Full, dead, and missing regions.
	servers[0].Open = 10
	i, _, ok = ChooseServer(servers, group)
	if !ok || servers[i].ID != 3 {
		t.Fatalf("eu full: %d %v", i, ok)
	}
	servers[2].Alive = false
	if _, _, ok = ChooseServer(servers, group); ok {
		t.Fatal("nothing usable")
	}
	// A region the players did not measure counts as UnknownLatencyMS.
	only := []ServerInfo{srv(5, "sa", 4, 0)}
	if _, worst, ok := ChooseServer(only, group); !ok || worst != UnknownLatencyMS {
		t.Fatalf("unknown region: %d %v", worst, ok)
	}
	// Reserved matches count against the capacity; ties go to the emptier server, then the lower id.
	a, b := srv(7, "eu", 10, 2), srv(8, "eu", 10, 1)
	i, _, _ = ChooseServer([]ServerInfo{a, b}, group)
	if i != 1 {
		t.Error("tie: more free capacity wins")
	}
	b.Reserved = 5
	i, _, _ = ChooseServer([]ServerInfo{a, b}, group)
	if i != 0 {
		t.Error("reservations reduce the free capacity")
	}
	// A server on another simulation hash is skipped.
	h := srv(9, "eu", 10, 0)
	h.SimHash = "new"
	g2 := []*Ticket{{Latencies: map[string]int{"eu": 10}, SimHash: "old"}}
	if _, _, ok := ChooseServer([]ServerInfo{h}, g2); ok {
		t.Error("sim hash mismatch")
	}
}

func TestPenaltyEscalatesAndDecays(t *testing.T) {
	p := DefaultParams() // 2 free strikes, 5 min base, 2 h max
	var st store.Penalty
	now := t0
	var bans []time.Duration
	for i := 0; i < 9; i++ {
		st = NextPenalty(st, now, p)
		if st.BannedUntil.After(now) {
			bans = append(bans, st.BannedUntil.Sub(now))
		} else {
			bans = append(bans, 0)
		}
		now = now.Add(time.Minute)
	}
	want := []time.Duration{0, 0, 5 * time.Minute, 10 * time.Minute, 20 * time.Minute, 40 * time.Minute, 80 * time.Minute, 2 * time.Hour, 2 * time.Hour}
	for i := range want {
		if bans[i] != want[i] {
			t.Errorf("strike %d: ban %v, want %v", i+1, bans[i], want[i])
		}
	}
	// A day without leaving clears the count.
	st = NextPenalty(st, now.Add(25*time.Hour), p)
	if st.Strikes != 1 || st.BannedUntil.After(now.Add(25*time.Hour)) {
		t.Errorf("after a quiet day: %+v", st)
	}
}
