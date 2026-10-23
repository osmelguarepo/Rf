package store_test

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"fuelrivals/backend/internal/store"
	"fuelrivals/backend/internal/testdb"
)

var ctx = context.Background()

// world is a store with a clock we control and one live server.
type world struct {
	t      *testing.T
	s      *store.Store
	now    time.Time
	server store.Server
	nextID int
}

func newWorld(t *testing.T) *world {
	t.Helper()
	s := testdb.New(t)
	w := &world{t: t, s: s, now: time.Date(2026, 10, 23, 12, 0, 0, 0, time.UTC)}
	s.Now = func() time.Time { return w.now }
	sv, key, err := s.RegisterServer(ctx, "eu-1", "eu", "wss://eu.example.com", 10)
	if err != nil || len(key) != 64 {
		t.Fatalf("register: %v %q", err, key)
	}
	w.server = sv
	w.beat()
	return w
}

func (w *world) beat() {
	w.t.Helper()
	if err := w.s.RecordHeartbeat(ctx, w.server.ID, store.Heartbeat{Capacity: 10}, 30*time.Second); err != nil {
		w.t.Fatal(err)
	}
}

// player creates a Steam player, with `points` set directly.
func (w *world) player(points int) store.Player {
	w.t.Helper()
	w.nextID++
	steam := fmt.Sprintf("7656119800%07d", w.nextID)
	p, err := w.s.UpsertSteamPlayer(ctx, steam, fmt.Sprintf("PLAYER%d", w.nextID))
	if err != nil {
		w.t.Fatal(err)
	}
	if _, err := w.s.Pool().Exec(ctx, `UPDATE ratings SET points = $2 WHERE player_id = $1`, p.ID, points); err != nil {
		w.t.Fatal(err)
	}
	return p
}

func (w *world) points(p store.Player) int {
	w.t.Helper()
	var n int
	if err := w.s.Pool().QueryRow(ctx, `SELECT points FROM ratings WHERE player_id = $1`, p.ID).Scan(&n); err != nil {
		w.t.Fatal(err)
	}
	return n
}

func seats(ps ...store.Player) []store.SeatRequest {
	out := make([]store.SeatRequest, len(ps))
	for i, p := range ps {
		out[i] = store.SeatRequest{PlayerID: p.ID, Seat: i, IPPrefix: fmt.Sprintf("10.0.%d", i)}
	}
	return out
}

func (w *world) assign(ps ...store.Player) store.Assignment {
	w.t.Helper()
	a, err := w.s.AssignMatch(ctx, store.AssignRequest{ServerID: w.server.ID, Seats: seats(ps...)})
	if err != nil {
		w.t.Fatalf("assign: %v", err)
	}
	return a
}

func result(ps []store.Player, places []int, abandoned ...int) []store.ResultEntry {
	out := make([]store.ResultEntry, len(ps))
	for i, p := range ps {
		out[i] = store.ResultEntry{PlayerID: p.ID, Place: places[i]}
	}
	for _, i := range abandoned {
		out[i].Abandoned = true
	}
	return out
}

func TestMigrateIsIdempotent(t *testing.T) {
	s := testdb.New(t)
	if err := s.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	var n int
	if err := s.Pool().QueryRow(ctx, `SELECT count(*) FROM schema_migrations`).Scan(&n); err != nil || n != 2 {
		t.Fatalf("%d %v", n, err)
	}
	// Partitions for this month and the next two.
	if err := s.EnsureReplayPartitions(ctx, 2); err != nil {
		t.Fatal(err)
	}
	if err := s.EnsureReplayPartitions(ctx, 2); err != nil {
		t.Fatalf("second call must be a no-op: %v", err)
	}
}

func TestSettlementAppliesTheTableAndStoresTheAppliedDelta(t *testing.T) {
	w := newWorld(t)
	a, b, c := w.player(0), w.player(10), w.player(300)
	ps := []store.Player{a, b, c}
	m := w.assign(ps...)
	if !m.Ranked || m.Bots != 3 {
		t.Fatalf("assignment %+v", m)
	}
	res, err := w.s.SettleMatch(ctx, m.MatchID, w.server.ID, result(ps, []int{3, 1, 2}))
	if err != nil {
		t.Fatal(err)
	}
	// 3 humans: 1st +25, 2nd 0, 3rd -25. a is last with 0 points: the floor applies.
	if w.points(a) != 0 || w.points(b) != 35 || w.points(c) != 300 {
		t.Errorf("points %d %d %d", w.points(a), w.points(b), w.points(c))
	}
	for _, p := range res.Players {
		if p.PlayerID == a.ID && (p.Applied != 0 || p.Before != 0 || p.After != 0) {
			t.Errorf("a: the applied delta is after the floor: %+v", p)
		}
		if p.PlayerID == b.ID && (p.Applied != 25 || p.FinalPlace != 1) {
			t.Errorf("b: %+v", p)
		}
	}
	// The stored applied delta of the floored player is 0, not -25.
	var applied int
	if err := w.s.Pool().QueryRow(ctx, `SELECT applied_delta FROM match_players WHERE match_id=$1 AND player_id=$2`, m.MatchID, a.ID).Scan(&applied); err != nil || applied != 0 {
		t.Errorf("applied %d %v", applied, err)
	}
}

func TestSettlementIsIdempotentAndFirstResultWins(t *testing.T) {
	w := newWorld(t)
	a, b := w.player(100), w.player(100)
	ps := []store.Player{a, b}
	m := w.assign(ps...)
	first := result(ps, []int{1, 2})
	if _, err := w.s.SettleMatch(ctx, m.MatchID, w.server.ID, first); err != nil {
		t.Fatal(err)
	}
	// The same report, in another order: nothing changes, and it says so.
	again, err := w.s.SettleMatch(ctx, m.MatchID, w.server.ID, []store.ResultEntry{first[1], first[0]})
	if err != nil || !again.Already {
		t.Fatalf("repeat: %+v %v", again, err)
	}
	if w.points(a) != 120 || w.points(b) != 80 {
		t.Fatalf("applied twice? %d %d", w.points(a), w.points(b))
	}
	// A different result: refused, points untouched, an alert recorded.
	_, err = w.s.SettleMatch(ctx, m.MatchID, w.server.ID, result(ps, []int{2, 1}))
	if !errors.Is(err, store.ErrConflict) {
		t.Fatalf("want conflict, got %v", err)
	}
	if w.points(a) != 120 || w.points(b) != 80 {
		t.Fatalf("conflict changed points: %d %d", w.points(a), w.points(b))
	}
	var alerts int
	if err := w.s.Pool().QueryRow(ctx, `SELECT count(*) FROM audit WHERE kind='result_conflict' AND severity='alert' AND match_id=$1`, m.MatchID).Scan(&alerts); err != nil || alerts != 1 {
		t.Errorf("alerts %d %v", alerts, err)
	}
	var ranked int
	_ = w.s.Pool().QueryRow(ctx, `SELECT ranked_matches FROM ratings WHERE player_id=$1`, a.ID).Scan(&ranked)
	if ranked != 1 {
		t.Errorf("ranked_matches %d", ranked)
	}
}

func TestConcurrentSettlementsApplyOnce(t *testing.T) {
	w := newWorld(t)
	a, b := w.player(100), w.player(100)
	ps := []store.Player{a, b}
	m := w.assign(ps...)
	rep := result(ps, []int{1, 2})
	errs := make(chan error, 8)
	for i := 0; i < 8; i++ {
		go func() { _, err := w.s.SettleMatch(ctx, m.MatchID, w.server.ID, rep); errs <- err }()
	}
	for i := 0; i < 8; i++ {
		if err := <-errs; err != nil {
			t.Fatal(err)
		}
	}
	if w.points(a) != 120 || w.points(b) != 80 {
		t.Fatalf("%d %d", w.points(a), w.points(b))
	}
}

func TestOnlyTheAssignedServerAndPlayersCanBeSettled(t *testing.T) {
	w := newWorld(t)
	a, b, outsider := w.player(0), w.player(0), w.player(0)
	m := w.assign(a, b)
	other, _, err := w.s.RegisterServer(ctx, "us-1", "us", "wss://us", 5)
	if err != nil {
		t.Fatal(err)
	}
	ps := []store.Player{a, b}
	if _, err := w.s.SettleMatch(ctx, m.MatchID, other.ID, result(ps, []int{1, 2})); !errors.Is(err, store.ErrForbidden) {
		t.Errorf("another server: %v", err)
	}
	for name, rep := range map[string][]store.ResultEntry{
		"outsider instead of b": {{PlayerID: a.ID, Place: 1}, {PlayerID: outsider.ID, Place: 2}},
		"missing player":        {{PlayerID: a.ID, Place: 1}},
		"extra player":          {{PlayerID: a.ID, Place: 1}, {PlayerID: b.ID, Place: 2}, {PlayerID: outsider.ID, Place: 3}},
		"duplicate place":       {{PlayerID: a.ID, Place: 1}, {PlayerID: b.ID, Place: 1}},
		"place 0":               {{PlayerID: a.ID, Place: 0}, {PlayerID: b.ID, Place: 1}},
		"place 7":               {{PlayerID: a.ID, Place: 7}, {PlayerID: b.ID, Place: 1}},
		"same player twice":     {{PlayerID: a.ID, Place: 1}, {PlayerID: a.ID, Place: 2}},
	} {
		if _, err := w.s.SettleMatch(ctx, m.MatchID, w.server.ID, rep); !errors.Is(err, store.ErrBadRequest) {
			t.Errorf("%s: %v", name, err)
		}
	}
	if _, err := w.s.SettleMatch(ctx, 999999, w.server.ID, result(ps, []int{1, 2})); !errors.Is(err, store.ErrNotFound) {
		t.Errorf("unknown match: %v", err)
	}
	if w.points(a) != 0 || w.points(b) != 0 {
		t.Error("a refused report must not move points")
	}
	// The match is still open and settles normally afterwards.
	if _, err := w.s.SettleMatch(ctx, m.MatchID, w.server.ID, result(ps, []int{1, 2})); err != nil {
		t.Fatal(err)
	}
}

func TestLeaverGetsLastPlaceAndTheRemainingHumanWins(t *testing.T) {
	w := newWorld(t)
	a, b := w.player(500), w.player(500)
	ps := []store.Player{a, b}
	m := w.assign(ps...)
	// a finished ahead on the road but left; b stayed.
	if _, err := w.s.SettleMatch(ctx, m.MatchID, w.server.ID, result(ps, []int{1, 4}, 0)); err != nil {
		t.Fatal(err)
	}
	if w.points(a) != 480 || w.points(b) != 520 {
		t.Errorf("a %d b %d", w.points(a), w.points(b))
	}
}

func TestPointsNeverGoBelowZeroAndAnnulRevertsTheAppliedDeltas(t *testing.T) {
	w := newWorld(t)
	a, b, c := w.player(10), w.player(0), w.player(1000)
	ps := []store.Player{a, b, c}
	m := w.assign(ps...)
	if _, err := w.s.SettleMatch(ctx, m.MatchID, w.server.ID, result(ps, []int{3, 2, 1})); err != nil {
		t.Fatal(err)
	}
	// a: 10-25 -> 0 (applied -10), b: 0 (applied 0), c: 1025.
	if w.points(a) != 0 || w.points(b) != 0 || w.points(c) != 1025 {
		t.Fatalf("%d %d %d", w.points(a), w.points(b), w.points(c))
	}
	res, err := w.s.AnnulMatch(ctx, m.MatchID, "cheating", "admin")
	if err != nil || res.Status != "annulled" || len(res.Reverted) != 3 {
		t.Fatalf("%+v %v", res, err)
	}
	// Exactly the applied deltas are taken back: a returns to 10, not to 35.
	if w.points(a) != 10 || w.points(b) != 0 || w.points(c) != 1000 {
		t.Errorf("after annul %d %d %d", w.points(a), w.points(b), w.points(c))
	}
	var ranked int
	var rating float64
	_ = w.s.Pool().QueryRow(ctx, `SELECT ranked_matches, rating FROM ratings WHERE player_id=$1`, c.ID).Scan(&ranked, &rating)
	if ranked != 0 || rating != 1500 {
		t.Errorf("hidden rating not restored: %d %v", ranked, rating)
	}
	// Annulling again does nothing; a late result is refused.
	if again, err := w.s.AnnulMatch(ctx, m.MatchID, "x", "admin"); err != nil || !again.Already || w.points(c) != 1000 {
		t.Errorf("second annul: %+v %v", again, err)
	}
	if _, err := w.s.SettleMatch(ctx, m.MatchID, w.server.ID, result(ps, []int{3, 2, 1})); !errors.Is(err, store.ErrGone) {
		t.Errorf("settle after annul: %v", err)
	}
}

func TestAnnulOfAnOpenMatchVoidsItAndFreesThePlayers(t *testing.T) {
	w := newWorld(t)
	a, b := w.player(0), w.player(0)
	m := w.assign(a, b)
	if _, err := w.s.AssignMatch(ctx, store.AssignRequest{ServerID: w.server.ID, Seats: seats(a, w.player(0))}); !errors.Is(err, store.ErrBusy) {
		t.Fatalf("a player in an open match cannot be assigned again: %v", err)
	}
	res, err := w.s.AnnulMatch(ctx, m.MatchID, "test", "admin")
	if err != nil || res.Status != "void" {
		t.Fatalf("%+v %v", res, err)
	}
	w.assign(a, b) // free again
}

func TestRankedRules(t *testing.T) {
	w := newWorld(t)
	check := func(name string, want bool, reason string, reqs func() []store.SeatRequest) {
		t.Helper()
		a, err := w.s.AssignMatch(ctx, store.AssignRequest{ServerID: w.server.ID, Seats: reqs()})
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if a.Ranked != want || a.Reason != reason {
			t.Errorf("%s: ranked=%v reason=%s, want %v %s", name, a.Ranked, a.Reason, want, reason)
		}
		if _, err := w.s.AnnulMatch(ctx, a.MatchID, "test", "test"); err != nil {
			t.Fatal(err)
		}
	}
	bronze, gold, plat := w.player(0), w.player(700), w.player(1200)
	check("one human", false, "fewer_than_2_ranked_humans", func() []store.SeatRequest { return seats(bronze) })
	check("bronze and gold: 2 divisions apart", true, "ranked", func() []store.SeatRequest { return seats(bronze, gold) })
	check("bronze and platinum: 3 apart", false, "division_gap", func() []store.SeatRequest { return seats(bronze, plat) })
	check("same /24", false, "same_subnet", func() []store.SeatRequest {
		return []store.SeatRequest{{PlayerID: bronze.ID, Seat: 0, IPPrefix: "1.2.3"}, {PlayerID: gold.ID, Seat: 1, IPPrefix: "1.2.3"}}
	})
	// A guest plus one human: not enough ranked humans; the guest never scores.
	g, err := w.s.CreateGuest(ctx, w.now.Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	check("guest and one human", false, "fewer_than_2_ranked_humans", func() []store.SeatRequest { return seats(g, bronze) })
}

func TestRepeatPairingsStopRankingOnTheFourthMeetingOfTheDay(t *testing.T) {
	w := newWorld(t)
	a, b := w.player(0), w.player(0)
	var got []bool
	for i := 0; i < 5; i++ {
		m := w.assign(a, b)
		got = append(got, m.Ranked)
		if _, err := w.s.AnnulMatch(ctx, m.MatchID, "t", "t"); err != nil {
			t.Fatal(err)
		}
	}
	want := []bool{true, true, true, false, false}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("meetings %v, want %v", got, want)
		}
	}
	// The next day the count starts again.
	w.now = w.now.Add(24 * time.Hour)
	w.beat()
	if m := w.assign(a, b); !m.Ranked {
		t.Error("a new day starts a new count")
	}
}

func TestGuestsNeverScore(t *testing.T) {
	w := newWorld(t)
	a, b := w.player(0), w.player(0)
	g, _ := w.s.CreateGuest(ctx, w.now.Add(time.Hour))
	ps := []store.Player{a, b, g}
	m := w.assign(ps...)
	if !m.Ranked {
		t.Fatalf("two Steam humans and a guest rank among the Steam humans: %+v", m)
	}
	if _, err := w.s.SettleMatch(ctx, m.MatchID, w.server.ID, result(ps, []int{3, 2, 1})); err != nil {
		t.Fatal(err)
	}
	// The field is the 2 scoring humans: b (place 2 of the scoring ones, first among them) beats a.
	if w.points(b) != 20 || w.points(a) != 0 {
		t.Errorf("a %d b %d", w.points(a), w.points(b))
	}
	var n int
	_ = w.s.Pool().QueryRow(ctx, `SELECT count(*) FROM ratings WHERE player_id=$1`, g.ID).Scan(&n)
	if n != 0 {
		t.Error("a guest has no rating")
	}
}

func TestAssignmentNeedsALiveServerWithRoom(t *testing.T) {
	w := newWorld(t)
	a, b := w.player(0), w.player(0)
	// Lease runs out.
	w.now = w.now.Add(31 * time.Second)
	if _, err := w.s.AssignMatch(ctx, store.AssignRequest{ServerID: w.server.ID, Seats: seats(a, b)}); !errors.Is(err, store.ErrDraining) {
		t.Errorf("expired lease: %v", err)
	}
	// Draining.
	w.now = w.now.Add(time.Second)
	if err := w.s.RecordHeartbeat(ctx, w.server.ID, store.Heartbeat{Capacity: 10, Draining: true}, 30*time.Second); err != nil {
		t.Fatal(err)
	}
	if _, err := w.s.AssignMatch(ctx, store.AssignRequest{ServerID: w.server.ID, Seats: seats(a, b)}); !errors.Is(err, store.ErrDraining) {
		t.Errorf("draining: %v", err)
	}
	// Full.
	if err := w.s.RecordHeartbeat(ctx, w.server.ID, store.Heartbeat{Capacity: 1}, 30*time.Second); err != nil {
		t.Fatal(err)
	}
	w.assign(a, b)
	c, d := w.player(0), w.player(0)
	if _, err := w.s.AssignMatch(ctx, store.AssignRequest{ServerID: w.server.ID, Seats: seats(c, d)}); !errors.Is(err, store.ErrDraining) {
		t.Errorf("full: %v", err)
	}
}

func TestSilentServerReleasesPlayersThenVoidsTheMatch(t *testing.T) {
	w := newWorld(t)
	a, b := w.player(0), w.player(0)
	m := w.assign(a, b)
	w.now = w.now.Add(time.Minute) // lease (30 s) is over
	res, err := w.s.ExpireLeases(ctx, 6*time.Hour)
	if err != nil || res.Released != 1 || res.Voided != 0 {
		t.Fatalf("%+v %v", res, err)
	}
	// The players are free: they can be assigned to a (restarted) server again.
	w.beat()
	m2 := w.assign(a, b)
	// The old server comes back and reports its match: still accepted (it was not voided yet).
	ps := []store.Player{a, b}
	if _, err := w.s.SettleMatch(ctx, m.MatchID, w.server.ID, result(ps, []int{1, 2})); err != nil {
		t.Fatalf("late result: %v", err)
	}
	if _, err := w.s.AnnulMatch(ctx, m2.MatchID, "t", "t"); err != nil {
		t.Fatal(err)
	}
	// Another silent match is voided after VoidAfter.
	m3 := w.assign(a, b)
	w.now = w.now.Add(7 * time.Hour)
	if res, err = w.s.ExpireLeases(ctx, 6*time.Hour); err != nil || res.Voided != 1 {
		t.Fatalf("%+v %v", res, err)
	}
	if _, err := w.s.SettleMatch(ctx, m3.MatchID, w.server.ID, result(ps, []int{1, 2})); !errors.Is(err, store.ErrGone) {
		t.Errorf("settling a voided match: %v", err)
	}
}

func TestReplayStorage(t *testing.T) {
	w := newWorld(t)
	a, b := w.player(0), w.player(0)
	m := w.assign(a, b)
	data := []byte("compressed-bytes-\x00\x01\x02")
	// The partitions exist before the first replay (the API does this at start-up); a month whose rows already sit in
	// the default partition cannot get one, and EnsureReplayPartitions says so.
	if err := w.s.EnsureReplayPartitions(ctx, 1); err != nil {
		t.Fatal(err)
	}
	if created, err := w.s.StoreReplay(ctx, m.MatchID, w.server.ID, "gzip-v1", data); err != nil || !created {
		t.Fatalf("%v %v", created, err)
	}
	if created, err := w.s.StoreReplay(ctx, m.MatchID, w.server.ID, "gzip-v1", data); err != nil || created {
		t.Fatalf("identical upload must be accepted without a new row: %v %v", created, err)
	}
	if _, err := w.s.StoreReplay(ctx, m.MatchID, w.server.ID, "gzip-v1", []byte("other")); !errors.Is(err, store.ErrConflict) {
		t.Errorf("different replay: %v", err)
	}
	other, _, _ := w.s.RegisterServer(ctx, "x", "x", "wss://x", 1)
	if _, err := w.s.StoreReplay(ctx, m.MatchID, other.ID, "gzip-v1", data); !errors.Is(err, store.ErrForbidden) {
		t.Errorf("another server: %v", err)
	}
	format, got, err := w.s.GetReplay(ctx, m.MatchID)
	if err != nil || format != "gzip-v1" || string(got) != string(data) {
		t.Fatalf("%q %q %v", format, got, err)
	}
	m2 := w.assign(w.player(0), w.player(0))
	if _, err := w.s.StoreReplay(ctx, m2.MatchID, w.server.ID, "gzip-v1", data); err != nil {
		t.Fatal(err)
	}
	var tbl string
	_ = w.s.Pool().QueryRow(ctx, `SELECT tableoid::regclass::text FROM replays WHERE match_id = $1`, m2.MatchID).Scan(&tbl)
	if tbl != "replays_2026_10" {
		t.Errorf("replay stored in %s", tbl)
	}
}

func TestServerKeysAreDerivedAndRotate(t *testing.T) {
	w := newWorld(t)
	_, key, _ := w.s.RegisterServer(ctx, "eu-1", "eu", "wss://eu.example.com", 10) // same name: rotates
	if _, err := w.s.AuthServer(ctx, w.server.IDString(), key); err != nil {
		t.Fatalf("new key: %v", err)
	}
	old := store.ServerKeyHex(testdb.MasterKey, w.server.ID, 1)
	if _, err := w.s.AuthServer(ctx, w.server.IDString(), old); !errors.Is(err, store.ErrForbidden) {
		t.Errorf("old key still works: %v", err)
	}
	for _, bad := range []string{"", "zz", key[:62], key + "00"} {
		if _, err := w.s.AuthServer(ctx, w.server.IDString(), bad); !errors.Is(err, store.ErrForbidden) {
			t.Errorf("key %q accepted", bad)
		}
	}
	if _, err := w.s.AuthServer(ctx, "999", key); !errors.Is(err, store.ErrForbidden) {
		t.Error("unknown server accepted")
	}
	if store.ServerKeyHex(testdb.MasterKey, 1, 1) == store.ServerKeyHex(testdb.MasterKey, 2, 1) {
		t.Error("keys must differ per server")
	}
}

func TestSessionsOnePerPlayerAndHashedAtRest(t *testing.T) {
	w := newWorld(t)
	p := w.player(0)
	t1, _, err := w.s.CreateSession(ctx, p.ID, "steam", time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	t2, _, _ := w.s.CreateSession(ctx, p.ID, "steam", time.Hour)
	if _, err := w.s.PlayerBySession(ctx, t1); !errors.Is(err, store.ErrNotFound) {
		t.Error("the old session must end when a new one starts")
	}
	if got, err := w.s.PlayerBySession(ctx, t2); err != nil || got.ID != p.ID {
		t.Fatalf("%v %v", got, err)
	}
	var n int
	_ = w.s.Pool().QueryRow(ctx, `SELECT count(*) FROM sessions WHERE token_hash = convert_to($1, 'UTF8')`, t2).Scan(&n)
	if n != 0 {
		t.Error("token stored in clear")
	}
	w.now = w.now.Add(2 * time.Hour)
	if _, err := w.s.PlayerBySession(ctx, t2); !errors.Is(err, store.ErrNotFound) {
		t.Error("expired session accepted")
	}
}

func TestExchangeCodeIsOneTimeAndExpires(t *testing.T) {
	w := newWorld(t)
	p := w.player(0)
	code, err := w.s.CreateExchangeCode(ctx, p.ID, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if got, err := w.s.RedeemExchangeCode(ctx, code); err != nil || got.ID != p.ID {
		t.Fatalf("%v %v", got, err)
	}
	if _, err := w.s.RedeemExchangeCode(ctx, code); !errors.Is(err, store.ErrNotFound) {
		t.Errorf("second use: %v", err)
	}
	code2, _ := w.s.CreateExchangeCode(ctx, p.ID, time.Minute)
	w.now = w.now.Add(61 * time.Second)
	if _, err := w.s.RedeemExchangeCode(ctx, code2); !errors.Is(err, store.ErrExpired) {
		t.Errorf("after 61 s: %v", err)
	}
	if _, err := w.s.RedeemExchangeCode(ctx, code2); !errors.Is(err, store.ErrNotFound) {
		t.Errorf("an expired code is gone: %v", err)
	}
}

func TestNonceStoreAcceptsOnce(t *testing.T) {
	w := newWorld(t)
	if ok, err := w.s.Fresh(ctx, "n1", w.now); err != nil || !ok {
		t.Fatal(ok, err)
	}
	if ok, _ := w.s.Fresh(ctx, "n1", w.now); ok {
		t.Fatal("seen twice")
	}
}

func TestBanSurvivesDeletionWithoutKeepingTheSteamID(t *testing.T) {
	w := newWorld(t)
	p := w.player(100)
	steam := p.SteamID
	if err := w.s.BanPlayer(ctx, p.ID, "cheating", "admin"); err != nil {
		t.Fatal(err)
	}
	if _, err := w.s.UpsertSteamPlayer(ctx, steam, "X"); !errors.Is(err, store.ErrBanned) {
		t.Fatalf("banned login: %v", err)
	}
	if err := w.s.DeleteAccount(ctx, p.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := w.s.UpsertSteamPlayer(ctx, steam, "X"); !errors.Is(err, store.ErrBanned) {
		t.Fatalf("a ban must survive deletion: %v", err)
	}
	var found int
	_ = w.s.Pool().QueryRow(ctx, `SELECT count(*) FROM bans WHERE steam_hash = convert_to($1, 'UTF8')`, steam).Scan(&found)
	var hashes int
	_ = w.s.Pool().QueryRow(ctx, `SELECT count(*) FROM bans`).Scan(&hashes)
	if found != 0 || hashes != 1 {
		t.Errorf("ban storage: plain=%d rows=%d", found, hashes)
	}
}

func TestDeleteAccountCleansEverything(t *testing.T) {
	w := newWorld(t)
	a, b := w.player(0), w.player(0)
	ps := []store.Player{a, b}
	m := w.assign(ps...)
	if err := w.s.DeleteAccount(ctx, a.ID); !errors.Is(err, store.ErrBusy) {
		t.Fatalf("deleting during a match: %v", err)
	}
	if _, err := w.s.SettleMatch(ctx, m.MatchID, w.server.ID, result(ps, []int{1, 2})); err != nil {
		t.Fatal(err)
	}
	if _, _, err := w.s.CreateSession(ctx, a.ID, "steam", time.Hour); err != nil {
		t.Fatal(err)
	}
	if err := w.s.AddReport(ctx, a.ID, b.ID, &m.MatchID, "x"); err != nil {
		t.Fatal(err)
	}
	if err := w.s.AddReport(ctx, b.ID, a.ID, &m.MatchID, "y"); err != nil {
		t.Fatal(err)
	}
	w.s.Audit(ctx, "test", "info", "t", nil, &a.ID, map[string]string{"steam": a.SteamID})

	if err := w.s.DeleteAccount(ctx, a.ID); err != nil {
		t.Fatal(err)
	}
	for table, where := range map[string]string{
		"sessions": "player_id", "ratings": "player_id", "match_players": "player_id", "pairings": "a", "audit": "player_id",
	} {
		var n int
		if err := w.s.Pool().QueryRow(ctx, fmt.Sprintf("SELECT count(*) FROM %s WHERE %s = $1", table, where), a.ID).Scan(&n); err != nil || n != 0 {
			t.Errorf("%s still has %d rows of the player (%v)", table, n, err)
		}
	}
	var n int
	_ = w.s.Pool().QueryRow(ctx, `SELECT count(*) FROM reports WHERE reporter = $1 OR target = $1`, a.ID).Scan(&n)
	if n != 0 {
		t.Errorf("reports left: %d", n)
	}
	var steam *string
	var name string
	if err := w.s.Pool().QueryRow(ctx, `SELECT steam_id, name FROM players WHERE player_id = $1`, a.ID).Scan(&steam, &name); err != nil || steam != nil || name != "DELETED" {
		t.Errorf("tombstone: %v %q %v", steam, name, err)
	}
	var leaked int
	_ = w.s.Pool().QueryRow(ctx, `SELECT count(*) FROM audit WHERE detail::text LIKE '%' || $1 || '%'`, a.SteamID).Scan(&leaked)
	if leaked != 0 {
		t.Error("the SteamID is still in the audit log")
	}
	if _, err := w.s.PlayerBySession(ctx, "anything"); err == nil {
		t.Error("no session should resolve")
	}
	// The other player's data is untouched, and the same SteamID can come back as a new, empty account.
	var bMatches int
	if err := w.s.Pool().QueryRow(ctx, `SELECT count(*) FROM match_players WHERE player_id = $1`, b.ID).Scan(&bMatches); err != nil || bMatches != 1 {
		t.Errorf("b lost data: %d %v", bMatches, err)
	}
	again, err := w.s.UpsertSteamPlayer(ctx, a.SteamID, "BACK")
	if err != nil || again.ID == a.ID {
		t.Fatalf("returning player: %+v %v", again, err)
	}
	if w.points(again) != 0 {
		t.Error("a returning player starts from 0")
	}
	if err := w.s.DeleteAccount(ctx, a.ID); err != nil {
		t.Errorf("deleting twice must be harmless: %v", err)
	}
}

func TestExportContainsTheOwnData(t *testing.T) {
	w := newWorld(t)
	a, b := w.player(0), w.player(0)
	ps := []store.Player{a, b}
	m := w.assign(ps...)
	_, _ = w.s.SettleMatch(ctx, m.MatchID, w.server.ID, result(ps, []int{1, 2}))
	_ = w.s.AddReport(ctx, a.ID, b.ID, &m.MatchID, "slow")
	ex, err := w.s.ExportAccount(ctx, a.ID)
	if err != nil {
		t.Fatal(err)
	}
	if ex.Player["steam_id"] == nil || len(ex.Matches) != 1 || len(ex.Reports) != 1 || ex.Rating["points"] != 20 {
		t.Errorf("%+v", ex)
	}
}

func TestProfileAndLeaderboard(t *testing.T) {
	w := newWorld(t)
	a, b, c := w.player(0), w.player(0), w.player(0)
	for _, p := range []store.Player{a, b, c} {
		_, _ = w.s.Pool().Exec(ctx, `UPDATE ratings SET ranked_matches = 3 WHERE player_id = $1`, p.ID)
	}
	_, _ = w.s.Pool().Exec(ctx, `UPDATE ratings SET points = 800 WHERE player_id = $1`, a.ID)
	_, _ = w.s.Pool().Exec(ctx, `UPDATE ratings SET points = 800 WHERE player_id = $1`, b.ID)
	_, _ = w.s.Pool().Exec(ctx, `UPDATE ratings SET points = 100 WHERE player_id = $1`, c.ID)
	fresh := w.player(0) // never played a ranked match: not listed
	lb, err := w.s.Leaderboard(ctx, 10)
	if err != nil || len(lb) != 3 {
		t.Fatalf("%+v %v", lb, err)
	}
	if lb[0].Rank != 1 || lb[1].Rank != 1 || lb[2].Rank != 3 || lb[0].DivisionName != "GOLD" {
		t.Errorf("ranks %+v", lb)
	}
	if lb, _ = w.s.Leaderboard(ctx, 1); len(lb) != 1 {
		t.Errorf("limit: %d", len(lb))
	}
	pa, _ := w.s.ProfileOf(ctx, a)
	pc, _ := w.s.ProfileOf(ctx, c)
	pf, _ := w.s.ProfileOf(ctx, fresh)
	if pa.Rank != 1 || pc.Rank != 3 || pa.ToNext != 400 || pf.Rank != 0 || !pa.Provisional {
		t.Errorf("%+v %+v %+v", pa, pc, pf)
	}
	g, _ := w.s.CreateGuest(ctx, w.now.Add(time.Hour))
	pg, _ := w.s.ProfileOf(ctx, g)
	if !pg.Guest || pg.Ranked || pg.Rank != 0 {
		t.Errorf("guest profile %+v", pg)
	}
}

func TestCleanupRemovesExpiredThings(t *testing.T) {
	w := newWorld(t)
	g, _ := w.s.CreateGuest(ctx, w.now.Add(time.Hour))
	_, _, _ = w.s.CreateSession(ctx, g.ID, "guest", time.Hour)
	_, _ = w.s.Fresh(ctx, "old", w.now)
	w.now = w.now.Add(8 * 24 * time.Hour)
	if err := w.s.Cleanup(ctx); err != nil {
		t.Fatal(err)
	}
	var n int
	_ = w.s.Pool().QueryRow(ctx, `SELECT (SELECT count(*) FROM sessions) + (SELECT count(*) FROM openid_nonces) + (SELECT count(*) FROM players WHERE is_guest)`).Scan(&n)
	if n != 0 {
		t.Errorf("%d rows left", n)
	}
}
