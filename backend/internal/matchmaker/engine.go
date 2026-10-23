package matchmaker

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"io"
	"log/slog"
	"sort"
	"strconv"
	"sync"
	"time"

	"fuelrivals/backend/internal/store"
	"fuelrivals/backend/internal/telemetry"
)

// Backend is what the engine needs from the database. *store.Store implements it.
type Backend interface {
	ListServers(ctx context.Context) ([]store.ServerState, error)
	ReserveMatchID(ctx context.Context) (int64, error)
	AssignMatch(ctx context.Context, req store.AssignRequest) (store.Assignment, error)
	PlayerOpenMatch(ctx context.Context, playerID int64) (int64, bool, error)
	LoadPenalty(ctx context.Context, playerID int64) (store.Penalty, error)
	SavePenalty(ctx context.Context, playerID int64, p store.Penalty) error
}

// Errors the HTTP layer maps to statuses.
var (
	ErrBusy       = errors.New("matchmaker: the player is in a match or a ready-check")
	ErrNoMatch    = errors.New("matchmaker: no such match for this player")
	ErrNotInQueue = errors.New("matchmaker: the player is not in the queue")
)

// BanError says the queue is closed to the player until Until.
type BanError struct{ Until time.Time }

func (e *BanError) Error() string {
	return "matchmaker: queue ban until " + e.Until.UTC().Format(time.RFC3339)
}

// States of GET /queue/status.
const (
	StateIdle     = "idle"
	StateWaiting  = "waiting"
	StateFound    = "found"
	StateReady    = "ready"
	StateStarting = "starting"
)

// Strike kinds (the label of fr_abandons_total).
const (
	StrikeReadyTimeout = "ready_timeout"
	StrikeReadyDecline = "ready_decline"
	StrikeLeftMatch    = "left_match"
)

// EnterInput is a player asking for a match.
type EnterInput struct {
	PlayerID  int64
	Guest     bool
	Points    int
	Rating    float64
	Latencies map[string]int
	IPPrefix  string
	SimHash   string
}

// MatchStatus is the "match" object of the status.
type MatchStatus struct {
	MatchID           string `json:"match_id"`
	ReadyDeadlineUnix int64  `json:"ready_deadline_unix"`
}

// Status is the answer of GET /queue/status.
type Status struct {
	State         string       `json:"state"`
	WaitS         int          `json:"wait_s"`
	BandDivisions int          `json:"band_divisions"`
	PlayersFound  int          `json:"players_found"`
	Match         *MatchStatus `json:"match,omitempty"`
	// Extras beyond the contract.
	Confirmed   int  `json:"players_confirmed,omitempty"`
	HighLatency bool `json:"high_latency,omitempty"`
}

type member struct {
	t         *Ticket
	confirmed bool
}

type pending struct {
	id          int64
	members     []*member
	serverID    int64
	highLatency bool
	created     time.Time
	deadline    time.Time
}

type startedInfo struct {
	matchID  int64
	at       time.Time
	deadline time.Time
	waitS    int
	players  int
}

// Engine is the live queue. All state is in memory under one mutex; the database is used for the things that must
// outlive a restart (matches, penalties) and for the checks that need it (open match, servers).
type Engine struct {
	p   Params
	be  Backend
	now func() time.Time
	log *slog.Logger
	m   *telemetry.Registry

	mu        sync.Mutex
	queue     map[int64]*Ticket
	pend      map[int64]*pending // by match id
	byPlayer  map[int64]*pending
	started   map[int64]startedInfo
	penalties map[int64]store.Penalty
	lastSrv   []store.ServerState
}

// NewEngine builds an engine. now, log and metrics may be nil.
func NewEngine(p Params, be Backend, now func() time.Time, log *slog.Logger, metrics *telemetry.Registry) *Engine {
	if now == nil {
		now = time.Now
	}
	if log == nil {
		log = slog.New(slog.NewJSONHandler(io.Discard, nil))
	}
	if metrics == nil {
		metrics = telemetry.New()
	}
	e := &Engine{p: p, be: be, now: now, log: log, m: metrics,
		queue: map[int64]*Ticket{}, pend: map[int64]*pending{}, byPlayer: map[int64]*pending{},
		started: map[int64]startedInfo{}, penalties: map[int64]store.Penalty{}}
	metrics.Gauge("fr_queue_size", "Players waiting in the queue.", func() float64 { e.mu.Lock(); defer e.mu.Unlock(); return float64(len(e.queue)) })
	metrics.Gauge("fr_pending_matches", "Matches found and waiting for confirmations.", func() float64 { e.mu.Lock(); defer e.mu.Unlock(); return float64(len(e.pend)) })
	metrics.Gauge("fr_servers_alive", "Game servers with a live lease.", func() float64 { return e.countServers(func(s store.ServerState) bool { return s.LeaseAlive }) })
	metrics.Gauge("fr_servers_draining", "Game servers draining.", func() float64 { return e.countServers(func(s store.ServerState) bool { return s.Draining }) })
	metrics.Gauge("fr_open_matches", "Matches assigned to game servers and not finished.", func() float64 {
		e.mu.Lock()
		defer e.mu.Unlock()
		n := 0
		for _, s := range e.lastSrv {
			n += s.OpenMatches
		}
		return float64(n)
	})
	return e
}

// Params returns the parameters in use.
func (e *Engine) Params() Params { return e.p }

func (e *Engine) countServers(f func(store.ServerState) bool) float64 {
	e.mu.Lock()
	defer e.mu.Unlock()
	n := 0
	for _, s := range e.lastSrv {
		if f(s) {
			n++
		}
	}
	return float64(n)
}

func newQueueID() string {
	var b [8]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

func cleanLatencies(in map[string]int) map[string]int {
	out := map[string]int{}
	for k, v := range in {
		if len(out) >= 16 {
			break
		}
		if len(k) == 0 || len(k) > 16 || v < 0 {
			continue
		}
		if v > 5000 {
			v = 5000
		}
		out[k] = v
	}
	return out
}

// penalty returns the cached penalty of a player, loading it on first use. mu may or may not be held by the caller:
// the cache is only touched under mu, the load is not.
func (e *Engine) penaltyOf(ctx context.Context, id int64) (store.Penalty, error) {
	e.mu.Lock()
	p, ok := e.penalties[id]
	e.mu.Unlock()
	if ok {
		return p, nil
	}
	p, err := e.be.LoadPenalty(ctx, id)
	if err != nil {
		return p, err
	}
	e.mu.Lock()
	if cur, ok := e.penalties[id]; ok {
		p = cur
	} else {
		e.penalties[id] = p
	}
	e.mu.Unlock()
	return p, nil
}

// Enter puts a player in the queue (POST /queue). It returns the queue id; asking again while waiting returns the same
// one. ErrBusy: the player is in a ready-check or an open match. *BanError: the queue is closed to the player.
func (e *Engine) Enter(ctx context.Context, in EnterInput) (string, error) {
	pen, err := e.penaltyOf(ctx, in.PlayerID)
	if err != nil {
		return "", err
	}
	now := e.now()
	if pen.BannedUntil.After(now) {
		return "", &BanError{Until: pen.BannedUntil}
	}
	e.mu.Lock()
	if t, ok := e.queue[in.PlayerID]; ok {
		id := t.QueueID
		e.mu.Unlock()
		return id, nil
	}
	if _, ok := e.byPlayer[in.PlayerID]; ok {
		e.mu.Unlock()
		return "", ErrBusy
	}
	e.mu.Unlock()
	if _, open, err := e.be.PlayerOpenMatch(ctx, in.PlayerID); err != nil {
		return "", err
	} else if open {
		return "", ErrBusy
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if t, ok := e.queue[in.PlayerID]; ok { // a concurrent request won
		return t.QueueID, nil
	}
	if _, ok := e.byPlayer[in.PlayerID]; ok {
		return "", ErrBusy
	}
	delete(e.started, in.PlayerID)
	t := &Ticket{PlayerID: in.PlayerID, QueueID: newQueueID(), Guest: in.Guest, Points: in.Points, Rating: in.Rating,
		Latencies: cleanLatencies(in.Latencies), IPPrefix: in.IPPrefix, SimHash: in.SimHash, EnteredAt: now}
	e.queue[in.PlayerID] = t
	e.m.Inc("fr_funnel_total", "Players that reached each stage of the funnel.", "stage", "queued")
	e.log.Info("queue", "event", "queue_enter", "player_id", in.PlayerID, "points", in.Points, "guest", in.Guest, "queue_size", len(e.queue))
	return t.QueueID, nil
}

// Leave is DELETE /queue. A waiting player is simply removed. A player whose match was found (state found or ready)
// declines it: that is a strike, and the others go on without them (see dropMember). Nothing happens when idle.
func (e *Engine) Leave(ctx context.Context, playerID int64) (previous string) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if _, ok := e.queue[playerID]; ok {
		delete(e.queue, playerID)
		e.m.Inc("fr_abandons_total", "Players that left the queue or a match, by kind.", "kind", "queue_cancel")
		e.log.Info("queue", "event", "queue_cancel", "player_id", playerID)
		return StateWaiting
	}
	if p, ok := e.byPlayer[playerID]; ok {
		prev := StateFound
		for _, m := range p.members {
			if m.t.PlayerID == playerID && m.confirmed {
				prev = StateReady
			}
		}
		e.strike(ctx, playerID, StrikeReadyDecline)
		e.dropMember(p, playerID)
		e.afterDrop(ctx, p)
		return prev
	}
	delete(e.started, playerID)
	return StateIdle
}

// Confirm is POST /queue/ready: the player accepts the found match.
func (e *Engine) Confirm(playerID, matchID int64) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	p, ok := e.byPlayer[playerID]
	if !ok || p.id != matchID {
		return ErrNoMatch
	}
	for _, m := range p.members {
		if m.t.PlayerID == playerID && !m.confirmed {
			m.confirmed = true
			e.m.Inc("fr_funnel_total", "Players that reached each stage of the funnel.", "stage", "ready")
			e.log.Info("queue", "event", "ready", "player_id", playerID, "match_id", matchID)
		}
	}
	return nil
}

// Status is GET /queue/status.
func (e *Engine) Status(playerID int64) Status {
	e.mu.Lock()
	defer e.mu.Unlock()
	now := e.now()
	if t, ok := e.queue[playerID]; ok {
		wait := t.Wait(now)
		found := 1
		for id, o := range e.queue {
			if id != playerID && e.p.Compatible(t, o, now) {
				found++
			}
		}
		if found > MaxField {
			found = MaxField
		}
		return Status{State: StateWaiting, WaitS: int(wait / time.Second), BandDivisions: e.p.Band(wait), PlayersFound: found}
	}
	if p, ok := e.byPlayer[playerID]; ok {
		st := Status{State: StateFound, PlayersFound: len(p.members), HighLatency: p.highLatency,
			Match: &MatchStatus{MatchID: itoa(p.id), ReadyDeadlineUnix: p.deadline.Unix()}}
		for _, m := range p.members {
			if m.confirmed {
				st.Confirmed++
			}
			if m.t.PlayerID == playerID {
				wait := m.t.Wait(now)
				st.WaitS, st.BandDivisions = int(wait/time.Second), e.p.Band(wait)
				if m.confirmed {
					st.State = StateReady
				}
			}
		}
		return st
	}
	if s, ok := e.started[playerID]; ok {
		return Status{State: StateStarting, WaitS: s.waitS, BandDivisions: AnyBand, PlayersFound: s.players,
			Match: &MatchStatus{MatchID: itoa(s.matchID), ReadyDeadlineUnix: s.deadline.Unix()}}
	}
	return Status{State: StateIdle}
}

// ForgetStarted drops the "starting" state of a player (they fetched the join ticket or left).
func (e *Engine) ForgetStarted(playerID int64) {
	e.mu.Lock()
	delete(e.started, playerID)
	e.mu.Unlock()
}

// Strike records a strike from outside the engine (a player who left a running match).
func (e *Engine) Strike(ctx context.Context, playerID int64, kind string) store.Penalty {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.strike(ctx, playerID, kind)
}

// ClearPenalty forgets the cached penalty of a player (after an admin lifted a ban).
func (e *Engine) ClearPenalty(playerID int64) {
	e.mu.Lock()
	delete(e.penalties, playerID)
	e.mu.Unlock()
}

// strike adds one strike and stores it. mu is held.
func (e *Engine) strike(ctx context.Context, playerID int64, kind string) store.Penalty {
	prev, ok := e.penalties[playerID]
	if !ok {
		if loaded, err := e.be.LoadPenalty(ctx, playerID); err == nil {
			prev = loaded
		}
	}
	next := NextPenalty(prev, e.now(), e.p)
	e.penalties[playerID] = next
	if err := e.be.SavePenalty(ctx, playerID, next); err != nil {
		e.log.Error("save penalty", "player_id", playerID, "err", err.Error())
	}
	e.m.Inc("fr_abandons_total", "Players that left the queue or a match, by kind.", "kind", kind)
	e.log.Warn("queue", "event", "strike", "player_id", playerID, "kind", kind, "strikes", next.Strikes,
		"banned_until", next.BannedUntil.Unix())
	return next
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

// dropMember removes a player from a pending match. mu is held.
func (e *Engine) dropMember(p *pending, playerID int64) {
	for i, m := range p.members {
		if m.t.PlayerID == playerID {
			p.members = append(p.members[:i], p.members[i+1:]...)
			break
		}
	}
	delete(e.byPlayer, playerID)
}

// afterDrop settles a pending match that lost a member. With fewer than 2 members left the match is cancelled and the
// rest go back to the queue with priority; with 2 or more it goes on (the next tick starts it once all confirm).
func (e *Engine) afterDrop(ctx context.Context, p *pending) {
	if len(p.members) >= 2 {
		return
	}
	e.cancelPending(p, "not_enough_players")
}

// cancelPending dissolves a pending match; the remaining members re-queue with priority. mu is held.
func (e *Engine) cancelPending(p *pending, why string) {
	for _, m := range p.members {
		e.requeue(m.t)
		delete(e.byPlayer, m.t.PlayerID)
	}
	delete(e.pend, p.id)
	e.log.Info("queue", "event", "match_cancelled", "match_id", p.id, "reason", why, "requeued", len(p.members))
}

func (e *Engine) requeue(t *Ticket) {
	t.Priority = true
	e.queue[t.PlayerID] = t
}

// Tick runs one second of the matching loop: it advances the ready-checks, then forms new groups from the queue.
func (e *Engine) Tick(ctx context.Context) {
	began := time.Now()
	servers, err := e.be.ListServers(ctx)
	if err != nil {
		e.log.Error("matchmaker: list servers", "err", err.Error())
		servers = nil
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	now := e.now()
	e.lastSrv = servers
	for id, s := range e.started {
		if now.Sub(s.at) > 2*time.Minute {
			delete(e.started, id)
		}
	}
	e.advancePending(ctx, now, servers)
	e.matchQueue(ctx, now, servers)
	e.m.Observe("fr_matchmaker_tick_seconds", "Duration of one pass of the matching loop.", telemetry.LatencyBuckets, time.Since(began).Seconds())
}

// serverInfos converts the stored servers, counting the matches reserved by pending ones (except `skip`).
func (e *Engine) serverInfos(servers []store.ServerState, skip *pending) []ServerInfo {
	reserved := map[int64]int{}
	for _, p := range e.pend {
		if p != skip {
			reserved[p.serverID]++
		}
	}
	out := make([]ServerInfo, 0, len(servers))
	for _, s := range servers {
		out = append(out, ServerInfo{ID: s.ID, Name: s.Name, Region: s.Region, URL: s.URL, Capacity: s.Capacity,
			Open: max(s.OpenMatches, s.ActiveMatches), Reserved: reserved[s.ID], SimHash: s.SimHash,
			Draining: s.Draining || s.DrainRequested, Alive: s.LeaseAlive})
	}
	return out
}

func (e *Engine) advancePending(ctx context.Context, now time.Time, servers []store.ServerState) {
	ids := make([]int64, 0, len(e.pend))
	for id := range e.pend {
		ids = append(ids, id)
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
	for _, id := range ids {
		p := e.pend[id]
		if p == nil {
			continue
		}
		confirmed := 0
		for _, m := range p.members {
			if m.confirmed {
				confirmed++
			}
		}
		switch {
		case len(p.members) == 0:
			delete(e.pend, id)
		case confirmed == len(p.members):
			e.start(ctx, now, p, servers)
		case !now.Before(p.deadline):
			// Those who did not confirm are dropped and struck; the others go on if two or more remain.
			var late []int64
			for _, m := range p.members {
				if !m.confirmed {
					late = append(late, m.t.PlayerID)
				}
			}
			for _, pid := range late {
				e.strike(ctx, pid, StrikeReadyTimeout)
				e.dropMember(p, pid)
			}
			if len(p.members) >= 2 {
				e.start(ctx, now, p, servers)
			} else {
				e.cancelPending(p, "ready_timeout")
			}
		}
	}
}

// start assigns the match (database record, seed, ranked verdict) with the members that confirmed. mu is held.
func (e *Engine) start(ctx context.Context, now time.Time, p *pending, servers []store.ServerState) {
	group := make([]*Ticket, len(p.members))
	for i, m := range p.members {
		group[i] = m.t
	}
	infos := e.serverInfos(servers, p)
	// Keep the server picked when the match was found if it is still usable; otherwise choose again.
	idx := -1
	for i, s := range infos {
		if s.ID == p.serverID && s.Usable() {
			idx = i
		}
	}
	if idx < 0 {
		var ok bool
		if idx, _, ok = ChooseServer(infos, group); !ok {
			e.m.Inc("fr_match_start_failures_total", "Matches that could not start, by reason.", "reason", "no_server")
			e.cancelPending(p, "no_server")
			return
		}
	}
	sv := infos[idx]
	seats := make([]store.SeatRequest, len(group))
	for i, t := range group {
		seats[i] = store.SeatRequest{PlayerID: t.PlayerID, Seat: i, IPPrefix: t.IPPrefix}
	}
	var gameVersion string
	for _, s := range servers {
		if s.ID == sv.ID {
			gameVersion = s.GameVersion
		}
	}
	a, err := e.be.AssignMatch(ctx, store.AssignRequest{ServerID: sv.ID, Seats: seats, GameVersion: gameVersion, SimHash: sv.SimHash, MatchID: p.id})
	if err != nil {
		e.m.Inc("fr_match_start_failures_total", "Matches that could not start, by reason.", "reason", "assign")
		e.log.Warn("matchmaker: assign failed", "match_id", p.id, "err", err.Error())
		if errors.Is(err, store.ErrBusy) {
			// Somebody is still in another open match: let them go, the rest try again.
			for _, t := range group {
				if _, open, qerr := e.be.PlayerOpenMatch(ctx, t.PlayerID); qerr == nil && open {
					e.dropMember(p, t.PlayerID)
				}
			}
		}
		e.cancelPending(p, "assign_failed")
		return
	}
	humans := len(a.Seats)
	waitSum := 0
	for _, t := range group {
		w := int(t.Wait(now) / time.Second)
		waitSum += w
		delete(e.byPlayer, t.PlayerID)
		e.started[t.PlayerID] = startedInfo{matchID: a.MatchID, at: now, deadline: p.deadline, waitS: w, players: humans}
		e.m.Inc("fr_funnel_total", "Players that reached each stage of the funnel.", "stage", "started")
	}
	delete(e.pend, p.id)
	filled := "full"
	if a.Bots > 0 {
		filled = "bots"
	}
	ranked := "false"
	if a.Ranked {
		ranked = "true"
	}
	e.m.Inc("fr_matches_started_total", "Matches started, by whether bots fill the field.", "filled", filled)
	e.m.Inc("fr_matches_ranked_total", "Matches started, by whether they score.", "ranked", ranked, "reason", a.Reason)
	e.m.Add("fr_match_humans_total", "Humans in started matches.", float64(humans))
	e.m.Add("fr_match_bots_total", "Bots in started matches.", float64(a.Bots))
	e.log.Info("queue", "event", "match_started", "match_id", a.MatchID, "server_id", sv.ID, "humans", humans, "bots", a.Bots,
		"ranked", a.Ranked, "rank_reason", a.Reason, "avg_wait_s", waitSum/max(humans, 1))
}

// matchQueue forms groups and turns each into a pending match (ready-check). mu is held.
func (e *Engine) matchQueue(ctx context.Context, now time.Time, servers []store.ServerState) {
	if len(e.queue) == 0 {
		return
	}
	infos := e.serverInfos(servers, nil)
	tickets := make([]*Ticket, 0, len(e.queue))
	for _, t := range e.queue {
		tickets = append(tickets, t)
	}
	sort.Slice(tickets, func(i, j int) bool { return tickets[i].PlayerID < tickets[j].PlayerID })
	groups := FormGroups(now, tickets, e.p, func(g *Group) bool {
		idx, worst, ok := ChooseServer(infos, g.Tickets)
		if !ok {
			return false
		}
		oldest := time.Duration(0)
		for _, t := range g.Tickets {
			oldest = max(oldest, t.Wait(now))
		}
		if worst > e.p.MaxPingMS {
			if oldest < e.p.MaxWait {
				return false // wait for a better server; after MaxWait it is accepted and the player is told
			}
			g.HighLatency = true
		}
		infos[idx].Reserved++
		g.ServerID = infos[idx].ID
		return true
	})
	for _, g := range groups {
		id, err := e.be.ReserveMatchID(ctx)
		if err != nil {
			e.log.Error("matchmaker: reserve match id", "err", err.Error())
			continue
		}
		p := &pending{id: id, serverID: g.ServerID, highLatency: g.HighLatency, created: now, deadline: now.Add(e.p.ReadyWindow)}
		for _, t := range g.Tickets {
			delete(e.queue, t.PlayerID)
			p.members = append(p.members, &member{t: t})
			e.byPlayer[t.PlayerID] = p
			e.m.Inc("fr_funnel_total", "Players that reached each stage of the funnel.", "stage", "found")
			e.m.Observe("fr_queue_wait_seconds", "Seconds a player waited until a match was found.", telemetry.WaitBuckets, t.Wait(now).Seconds())
		}
		e.pend[id] = p
		e.log.Info("queue", "event", "match_found", "match_id", id, "server_id", g.ServerID, "humans", len(g.Tickets),
			"reason", g.Reason, "high_latency", g.HighLatency)
	}
}

// Finished counts a match that ended (called when a result is settled).
func (e *Engine) Finished(matchID int64, humans int, bots int) {
	e.m.Add("fr_funnel_total", "Players that reached each stage of the funnel.", float64(humans), "stage", "finished")
	e.log.Info("queue", "event", "match_finished", "match_id", matchID, "humans", humans, "bots", bots)
}

// QueueEntry and PendingEntry are the admin view of the live state.
type QueueEntry struct {
	PlayerID string `json:"player_id"`
	Points   int    `json:"points"`
	Guest    bool   `json:"guest"`
	WaitS    int    `json:"wait_s"`
	Band     int    `json:"band_divisions"`
	Priority bool   `json:"priority"`
}

// PendingEntry is a found match waiting for confirmations.
type PendingEntry struct {
	MatchID   string   `json:"match_id"`
	ServerID  string   `json:"server_id"`
	Players   []string `json:"players"`
	Confirmed []string `json:"confirmed"`
	Deadline  int64    `json:"ready_deadline_unix"`
}

// Snapshot lists the queue and the pending matches.
func (e *Engine) Snapshot() ([]QueueEntry, []PendingEntry) {
	e.mu.Lock()
	defer e.mu.Unlock()
	now := e.now()
	q := make([]QueueEntry, 0, len(e.queue))
	for _, t := range e.queue {
		q = append(q, QueueEntry{PlayerID: itoa(t.PlayerID), Points: t.Points, Guest: t.Guest, WaitS: int(t.Wait(now) / time.Second),
			Band: e.p.Band(t.Wait(now)), Priority: t.Priority})
	}
	sort.Slice(q, func(i, j int) bool { return q[i].WaitS > q[j].WaitS })
	pe := make([]PendingEntry, 0, len(e.pend))
	for _, p := range e.pend {
		x := PendingEntry{MatchID: itoa(p.id), ServerID: itoa(p.serverID), Deadline: p.deadline.Unix(), Players: []string{}, Confirmed: []string{}}
		for _, m := range p.members {
			x.Players = append(x.Players, itoa(m.t.PlayerID))
			if m.confirmed {
				x.Confirmed = append(x.Confirmed, itoa(m.t.PlayerID))
			}
		}
		pe = append(pe, x)
	}
	sort.Slice(pe, func(i, j int) bool { return pe[i].MatchID < pe[j].MatchID })
	return q, pe
}
