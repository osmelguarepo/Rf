// Package matchmaker is the queue of docs/SPEC_ONLINE.md section 7 as corrected by section 16, described in
// docs/MATCHMAKING.md. This file is the pure part: it decides who plays together and on which server, with no clock,
// no database and no locks, so it can be tested with synthetic queues.
package matchmaker

import (
	"sort"
	"time"

	"fuelrivals/backend/internal/ranking"
)

const (
	// AnyBand is the band that accepts any division (there are 5, so the largest gap is 4).
	AnyBand = 5
	// UnknownLatencyMS is assumed for a region the player did not measure.
	UnknownLatencyMS = 200
	// MaxField is the number of cars of a race.
	MaxField = 6
)

// Params are the matchmaking parameters (environment variables in docs/MATCHMAKING.md).
type Params struct {
	MaxWait     time.Duration // QUEUE_MAX_WAIT: a group of 2 or more launches when its oldest ticket has waited this long
	SoloWait    time.Duration // QUEUE_SOLO_WAIT: a single human waiting this long gets a race against bots
	BandStep    time.Duration // the band grows one division every BandStep of the newer ticket's wait (10 s)
	ReadyWindow time.Duration // READY_SECONDS: time to confirm a found match
	MaxPingMS   int           // MAX_PING_MS: above this the group waits for MaxWait before it accepts the server

	PenaltyFree   int           // PENALTY_FREE_STRIKES: strikes in the window that carry no ban
	PenaltyBase   time.Duration // PENALTY_BASE: the first ban; it doubles with each further strike
	PenaltyMax    time.Duration // PENALTY_MAX: the longest ban
	PenaltyWindow time.Duration // strikes older than this are forgotten (24 h)
}

// DefaultParams are the values of SPEC_ONLINE 7 and 16.
func DefaultParams() Params {
	return Params{
		MaxWait: 30 * time.Second, SoloWait: 30 * time.Second, BandStep: 10 * time.Second, ReadyWindow: 15 * time.Second,
		MaxPingMS: 250, PenaltyFree: 2, PenaltyBase: 5 * time.Minute, PenaltyMax: 2 * time.Hour, PenaltyWindow: 24 * time.Hour,
	}
}

// Band is how many divisions apart two tickets may be when the newer of them has waited `wait`: 1 on entering, one
// more each BandStep, and any division from three steps on (30 s by default).
func (p Params) Band(wait time.Duration) int {
	if wait < 0 {
		wait = 0
	}
	n := int(wait / p.BandStep)
	if n >= 3 {
		return AnyBand
	}
	return 1 + n
}

// Ticket is one waiting player.
type Ticket struct {
	PlayerID  int64
	QueueID   string
	Guest     bool
	Points    int
	Rating    float64 // hidden rating; breaks ties, never shown
	Latencies map[string]int
	IPPrefix  string // the /24, in memory only
	SimHash   string // "" accepts any
	EnteredAt time.Time
	Priority  bool // re-queued after a failed ready-check: served first
}

// Division of the ticket (guests are in the first one).
func (t *Ticket) Division() int { return ranking.Division(t.Points) }

// Wait is how long the ticket has waited at `now`.
func (t *Ticket) Wait(now time.Time) time.Duration { return now.Sub(t.EnteredAt) }

// Compatible reports whether two tickets may share a match at `now`: same simulation hash (when both give one) and
// divisions no further apart than the band of the NEWER ticket.
func (p Params) Compatible(a, b *Ticket, now time.Time) bool {
	if a.SimHash != "" && b.SimHash != "" && a.SimHash != b.SimHash {
		return false
	}
	wait := a.Wait(now)
	if w := b.Wait(now); w < wait {
		wait = w
	}
	gap := a.Division() - b.Division()
	if gap < 0 {
		gap = -gap
	}
	return gap <= p.Band(wait)
}

// Group is a set of humans that will play together; the rest of the 6 cars are bots.
type Group struct {
	Tickets []*Ticket
	// Reason is why it launched: "full" (6 humans), "timeout" (2 to 5 and the oldest waited MaxWait) or "solo".
	Reason string
	// Filled by the caller's accept function.
	ServerID    int64
	HighLatency bool
}

// Bots is how many cars are bots.
func (g Group) Bots() int { return MaxField - len(g.Tickets) }

// FormGroups runs one pass of the matching loop (SPEC_ONLINE 7 and 16.4):
//
//  1. tickets are sorted by points;
//  2. starting from the ticket that has waited longest (re-queued ones first), it gathers the compatible tickets, those
//     of other subnets and closest in points first, as long as each is compatible with everyone already in the group;
//  3. the group launches when it reaches 6, or when it has 2 to 5 and its oldest ticket has waited MaxWait; a lone
//     ticket launches against bots after SoloWait.
//
// accept is asked before a group is taken (it may refuse because no server is free, and may fill ServerID); a refused
// group leaves its tickets in the queue for other groups and the next pass. No ticket is in two groups.
func FormGroups(now time.Time, queue []*Ticket, p Params, accept func(*Group) bool) []Group {
	byPoints := append([]*Ticket(nil), queue...)
	sort.SliceStable(byPoints, func(i, j int) bool {
		a, b := byPoints[i], byPoints[j]
		if a.Points != b.Points {
			return a.Points < b.Points
		}
		if !a.EnteredAt.Equal(b.EnteredAt) {
			return a.EnteredAt.Before(b.EnteredAt)
		}
		return a.PlayerID < b.PlayerID
	})
	anchors := append([]*Ticket(nil), byPoints...)
	sort.SliceStable(anchors, func(i, j int) bool {
		a, b := anchors[i], anchors[j]
		if a.Priority != b.Priority {
			return a.Priority
		}
		if !a.EnteredAt.Equal(b.EnteredAt) {
			return a.EnteredAt.Before(b.EnteredAt)
		}
		return a.PlayerID < b.PlayerID
	})

	used := map[*Ticket]bool{}
	var out []Group
	for _, a := range anchors {
		if used[a] {
			continue
		}
		members := []*Ticket{a}
		var cands []*Ticket
		for _, c := range byPoints {
			if c != a && !used[c] && p.Compatible(a, c, now) {
				cands = append(cands, c)
			}
		}
		sort.SliceStable(cands, func(i, j int) bool {
			ci, cj := cands[i], cands[j]
			si, sj := sameSubnet(a, ci), sameSubnet(a, cj)
			if si != sj {
				return !si
			}
			di, dj := abs(ci.Points-a.Points), abs(cj.Points-a.Points)
			if di != dj {
				return di < dj
			}
			return ci.PlayerID < cj.PlayerID
		})
		for _, c := range cands {
			if len(members) == MaxField {
				break
			}
			ok := true
			for _, m := range members[1:] {
				if !p.Compatible(c, m, now) {
					ok = false
					break
				}
			}
			if ok {
				members = append(members, c)
			}
		}
		oldest := time.Duration(0)
		for _, m := range members {
			if w := m.Wait(now); w > oldest {
				oldest = w
			}
		}
		reason := ""
		switch {
		case len(members) == MaxField:
			reason = "full"
		case len(members) >= 2 && oldest >= p.MaxWait:
			reason = "timeout"
		case len(members) == 1 && a.Wait(now) >= p.SoloWait:
			reason = "solo"
		}
		if reason == "" {
			continue
		}
		g := Group{Tickets: members, Reason: reason}
		if accept != nil && !accept(&g) {
			continue
		}
		for _, m := range members {
			used[m] = true
		}
		out = append(out, g)
	}
	return out
}

func sameSubnet(a, b *Ticket) bool { return a.IPPrefix != "" && a.IPPrefix == b.IPPrefix }

func abs(x int) int {
	if x < 0 {
		return -x
	}
	return x
}

// ServerInfo is a game server as the chooser sees it.
type ServerInfo struct {
	ID       int64
	Name     string
	Region   string
	URL      string
	Capacity int
	Open     int // matches running or assigned
	Reserved int // matches found and not started yet
	SimHash  string
	Draining bool
	Alive    bool // lease not expired
}

// Free is how many more matches the server can take.
func (s ServerInfo) Free() int { return s.Capacity - s.Open - s.Reserved }

// Usable says whether new matches may go to the server.
func (s ServerInfo) Usable() bool { return s.Alive && !s.Draining && s.Free() > 0 }

// MaxLatency is the highest latency the group's players measured to a region.
func MaxLatency(g []*Ticket, region string) int {
	worst := 0
	for _, t := range g {
		ms, ok := t.Latencies[region]
		if !ok {
			ms = UnknownLatencyMS
		}
		if ms > worst {
			worst = ms
		}
	}
	return worst
}

// ChooseServer picks, among the usable servers that run the group's simulation version, the one with the lowest
// maximum latency over the group; ties go to the one with more free capacity, then the lower id. It returns the index
// into servers and that latency.
func ChooseServer(servers []ServerInfo, g []*Ticket) (int, int, bool) {
	best, bestMax := -1, 0
	for i, s := range servers {
		if !s.Usable() {
			continue
		}
		fits := true
		for _, t := range g {
			if t.SimHash != "" && s.SimHash != "" && t.SimHash != s.SimHash {
				fits = false
				break
			}
		}
		if !fits {
			continue
		}
		m := MaxLatency(g, s.Region)
		if best < 0 || m < bestMax ||
			(m == bestMax && (s.Free() > servers[best].Free() || (s.Free() == servers[best].Free() && s.ID < servers[best].ID))) {
			best, bestMax = i, m
		}
	}
	return best, bestMax, best >= 0
}
