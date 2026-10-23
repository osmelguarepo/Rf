package store_test

import (
	"errors"
	"testing"
	"time"

	"fuelrivals/backend/internal/store"
)

func TestServersListDrainAndHeartbeat(t *testing.T) {
	w := newWorld(t)
	list, err := w.s.ListServers(ctx)
	if err != nil || len(list) != 1 || !list[0].LeaseAlive || list[0].OpenMatches != 0 || list[0].Draining {
		t.Fatalf("%+v %v", list, err)
	}
	a, b := w.player(0), w.player(0)
	w.assign(a, b)
	list, _ = w.s.ListServers(ctx)
	if list[0].OpenMatches != 1 {
		t.Errorf("open matches %d", list[0].OpenMatches)
	}
	// An operator drains the server: new matches are refused, and a heartbeat that does not say draining does not undo it.
	if err := w.s.SetDrain(ctx, w.server.ID, true); err != nil {
		t.Fatal(err)
	}
	w.beat()
	list, _ = w.s.ListServers(ctx)
	if !list[0].Draining || !list[0].DrainRequested {
		t.Fatalf("%+v", list[0])
	}
	if d, err := w.s.DrainRequested(ctx, w.server.ID); err != nil || !d {
		t.Fatalf("%v %v", d, err)
	}
	c, d := w.player(0), w.player(0)
	if _, err := w.s.AssignMatch(ctx, store.AssignRequest{ServerID: w.server.ID, Seats: seats(c, d)}); !errors.Is(err, store.ErrDraining) {
		t.Fatalf("assign to a drained server: %v", err)
	}
	if err := w.s.SetDrain(ctx, w.server.ID, false); err != nil {
		t.Fatal(err)
	}
	w.beat()
	w.assign(c, d)
	if err := w.s.SetDrain(ctx, 9999, true); !errors.Is(err, store.ErrNotFound) {
		t.Errorf("unknown server: %v", err)
	}
	// The lease runs out.
	w.now = w.now.Add(time.Minute)
	list, _ = w.s.ListServers(ctx)
	if list[0].LeaseAlive {
		t.Error("lease should have expired")
	}
}

func TestReservedMatchIDIsUsedByAssign(t *testing.T) {
	w := newWorld(t)
	id, err := w.s.ReserveMatchID(ctx)
	if err != nil || id <= 0 {
		t.Fatal(id, err)
	}
	a, b := w.player(0), w.player(0)
	m, err := w.s.AssignMatch(ctx, store.AssignRequest{ServerID: w.server.ID, Seats: seats(a, b), MatchID: id})
	if err != nil || m.MatchID != id {
		t.Fatalf("%+v %v", m, err)
	}
	if open, ok, err := w.s.PlayerOpenMatch(ctx, a.ID); err != nil || !ok || open != id {
		t.Errorf("open match %d %v %v", open, ok, err)
	}
	c := w.player(0)
	if _, ok, _ := w.s.PlayerOpenMatch(ctx, c.ID); ok {
		t.Error("a free player has no open match")
	}
	// Without a reserved id the sequence goes on after it.
	m2 := w.assign(c, w.player(0))
	if m2.MatchID <= id {
		t.Errorf("ids %d then %d", id, m2.MatchID)
	}
}

func TestPenaltyCountersAreStored(t *testing.T) {
	w := newWorld(t)
	p := w.player(0)
	if got, err := w.s.LoadPenalty(ctx, p.ID); err != nil || got.Strikes != 0 || !got.BannedUntil.IsZero() {
		t.Fatalf("%+v %v", got, err)
	}
	want := store.Penalty{Strikes: 3, LastAt: w.now, BannedUntil: w.now.Add(5 * time.Minute)}
	if err := w.s.SavePenalty(ctx, p.ID, want); err != nil {
		t.Fatal(err)
	}
	want.Strikes = 4
	if err := w.s.SavePenalty(ctx, p.ID, want); err != nil {
		t.Fatal(err)
	}
	got, _ := w.s.LoadPenalty(ctx, p.ID)
	if got.Strikes != 4 || !got.BannedUntil.Equal(want.BannedUntil) || !got.LastAt.Equal(want.LastAt) {
		t.Fatalf("%+v", got)
	}
	if err := w.s.ClearPenalty(ctx, p.ID); err != nil {
		t.Fatal(err)
	}
	if got, _ := w.s.LoadPenalty(ctx, p.ID); got.Strikes != 0 {
		t.Error("cleared")
	}
}

func TestJoinSeatLeaveAndVoid(t *testing.T) {
	w := newWorld(t)
	a, b := w.player(0), w.player(0)
	m := w.assign(a, b)

	j, err := w.s.SeatOf(ctx, m.MatchID, a.ID)
	if err != nil || j.ServerID != w.server.ID || j.Status != "assigned" || j.SteamID != a.SteamID || j.Seed != m.Seed || j.JoinIssuedAt != nil {
		t.Fatalf("%+v %v", j, err)
	}
	if _, err := w.s.SeatOf(ctx, m.MatchID, w.player(0).ID); !errors.Is(err, store.ErrNotFound) {
		t.Errorf("a stranger has no seat: %v", err)
	}
	first, err := w.s.MarkJoinIssued(ctx, m.MatchID, a.ID)
	if err != nil {
		t.Fatal(err)
	}
	w.now = w.now.Add(10 * time.Second)
	again, _ := w.s.MarkJoinIssued(ctx, m.MatchID, a.ID)
	if !again.Equal(first) {
		t.Errorf("the first moment stays: %v %v", first, again)
	}

	// A leaves after joining; B is still in: the match goes on, A is free to queue again.
	res, err := w.s.MarkLeft(ctx, m.MatchID, a.ID)
	if err != nil || res.Already || !res.Joined || res.Voided || res.Status != "assigned" {
		t.Fatalf("%+v %v", res, err)
	}
	if _, ok, _ := w.s.PlayerOpenMatch(ctx, a.ID); ok {
		t.Error("a player who left is not in the match any more")
	}
	if res, _ := w.s.MarkLeft(ctx, m.MatchID, a.ID); !res.Already {
		t.Error("leaving twice")
	}
	// B leaves without ever getting a ticket: nobody is left, the match is void.
	res, err = w.s.MarkLeft(ctx, m.MatchID, b.ID)
	if err != nil || res.Joined || !res.Voided || res.Status != "void" {
		t.Fatalf("%+v %v", res, err)
	}
	if _, err := w.s.SettleMatch(ctx, m.MatchID, w.server.ID, result([]store.Player{a, b}, []int{1, 2})); !errors.Is(err, store.ErrGone) {
		t.Errorf("a void match cannot be settled: %v", err)
	}
	if _, err := w.s.MarkLeft(ctx, 99999, a.ID); !errors.Is(err, store.ErrNotFound) {
		t.Errorf("unknown match: %v", err)
	}
}

func TestListMatchesAndUnban(t *testing.T) {
	w := newWorld(t)
	a, b, c, d := w.player(0), w.player(0), w.player(0), w.player(0)
	m1 := w.assign(a, b)
	m2 := w.assign(c, d)
	if _, err := w.s.AnnulMatch(ctx, m2.MatchID, "x", "admin"); err != nil {
		t.Fatal(err)
	}
	all, err := w.s.ListMatches(ctx, "", 10)
	if err != nil || len(all) != 2 || all[0].MatchID != m2.MatchID {
		t.Fatalf("%+v %v", all, err)
	}
	open, _ := w.s.ListMatches(ctx, "assigned", 10)
	if len(open) != 1 || open[0].MatchID != m1.MatchID || open[0].Humans != 2 || open[0].Bots != 4 {
		t.Fatalf("%+v", open)
	}
	humans, _ := w.s.MatchHumans(ctx, m1.MatchID)
	if len(humans) != 2 || humans[0] != a.ID {
		t.Errorf("%v", humans)
	}

	if err := w.s.BanPlayer(ctx, a.ID, "test", "admin"); err != nil {
		t.Fatal(err)
	}
	if _, err := w.s.UpsertSteamPlayer(ctx, a.SteamID, "X"); !errors.Is(err, store.ErrBanned) {
		t.Fatalf("banned: %v", err)
	}
	if err := w.s.UnbanPlayer(ctx, a.ID, "admin"); err != nil {
		t.Fatal(err)
	}
	if _, err := w.s.UpsertSteamPlayer(ctx, a.SteamID, "X"); err != nil {
		t.Fatalf("after unban: %v", err)
	}
	if err := w.s.UnbanPlayer(ctx, 99999, "admin"); !errors.Is(err, store.ErrNotFound) {
		t.Errorf("%v", err)
	}
}
