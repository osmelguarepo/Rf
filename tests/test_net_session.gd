extends "res://tests/test_case.gd"
## The online client end to end (scripts/net/online_session.gd, rollback.gd) against a real Room over the loopback, on a
## virtual clock (tools/net_harness.gd): the acceptance of docs/SPEC_ONLINE.md §13 M2 and §16.7. Six simulated clients, 150 ms
## one way, 30 ms of jitter, stalls and a little loss: after a 3-race match every client's confirmed state equals the server's at
## every confirmed tick, and nobody needed a resync.

const Harness := preload("res://tools/net_harness.gd")
const OnlineSession := preload("res://scripts/net/online_session.gd")
const Room := preload("res://scripts/server/room.gd")
const Match := preload("res://scripts/sim/match.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")

## Short races, so that a match is a few thousand ticks.
const SHORT := {"race_finish_px": 1800.0, "match_races": 3}

var _made: Array[Harness] = []


func after_each() -> void:
	for h in _made:
		h.dispose()
	_made = []


## A harness that is disposed of when the test is over, even if it failed.
func _make(options: Dictionary) -> Harness:
	var h := Harness.new(options)
	_made.append(h)
	return h


func _six(h: Harness, latency: int, jitter: int, loss: float = 0.0) -> void:
	for seat in 6:
		h.add_client(seat, latency, jitter, loss)


## Every client's confirmed states against the server's: no mismatch, and most of the match was compared.
func _all_equal(h: Harness) -> void:
	var ticks := h.room().tick - h.room().start_tick
	for c in h.clients:
		var got := h.compare(c)
		assert_eq(got["mismatches"], 0, "seat %d: first different tick %d" % [c.seat, got["first_bad"]])
		assert_gt(got["checked"], ticks - 60, "seat %d compared nearly every tick" % c.seat)


func test_six_clients_with_latency_jitter_stalls_and_loss_play_a_3_race_match_in_step_with_the_server() -> void:
	var h := _make({"tuning": SHORT})
	_six(h, 150, 30, 0.02)
	h.run_ms(25000)
	h.clients[1].link.stall(1200)
	h.clients[4].link.stall(700)
	h.run_ms(20000)
	h.clients[2].link.stall(2500)
	assert_true(h.run_until_over(400000), "the match ended")
	h.run_ms(3000)
	var room := h.room()
	assert_true(room.result()["complete"])
	assert_eq(room.game.rounds_played(), 3, "three races")
	_all_equal(h)
	for c in h.clients:
		assert_eq(c.session.resyncs, 0, "seat %d needed no resync" % c.seat)
		assert_eq(c.session.desyncs, 0)
		assert_gt(c.session.checksums_ok, 20, "and the server's checksums were checked")
		assert_eq(c.session.state, OnlineSession.State.ENDED)
		assert_eq(c.session.end_info["winner"], room.game.winner, "the end EVENT says who won")
		assert_eq(c.session.confirmed_match().checksum(), room.game.checksum(), "the very same final state")
	assert_eq(room.counters.get("snapshots", 0), 0, "no snapshot was needed")


func test_a_client_with_600_ms_of_latency_does_not_corrupt_the_others() -> void:
	var h := _make({"tuning": {"race_finish_px": 1800.0, "match_races": 1}})
	for seat in 5:
		h.add_client(seat, 70, 10)
	var slow := h.add_client(5, 600, 60, 0.05)
	assert_true(h.run_until_over(300000))
	h.run_ms(4000)
	_all_equal(h)
	for c in h.clients:
		assert_eq(c.session.resyncs, 0)
	assert_gt(h.room().counters.get("late_inputs", 0), 20, "the slow client's inputs arrived after their tick")
	assert_gt(slow.session.rollback.rebuilds, 0)
	# Its car was driven by repeats of its last input, and the others' predictions of it are no worse for it.
	var fast_depth := Harness.percentile(h.clients[0].session.rollback.depths, 0.99)
	assert_lt(fast_depth, 20.0, "a fast client's rollbacks stay shallow")


func test_the_prediction_freezes_during_a_stall_and_the_client_catches_up_after() -> void:
	var h := _make({"humans": 0b000011, "tuning": SHORT})
	h.add_client(0, 80, 10)
	var c := h.add_client(1, 80, 10)
	h.run_ms(15000)
	c.link.stall(4000)
	var deepest := 0
	for i in 300:
		h.step()
		deepest = maxi(deepest, c.session.rollback.lead())
	assert_between(deepest, 0, OnlineSession.Rollback.MAX_PREDICT, "it never guesses further than max_predict ticks ahead")
	assert_gt(deepest, 30, "but it did run ahead")
	h.run_ms(6000)
	assert_lt(c.session.rollback.lead(), 40, "and is back on the clock after the stall")
	assert_eq(c.session.resyncs, 0)
	assert_eq(h.compare(c)["mismatches"], 0)
	assert_eq(h.compare(h.clients[0])["mismatches"], 0, "the other client never noticed")


func test_a_checksum_that_differs_asks_for_a_snapshot_and_the_client_is_back_in_step() -> void:
	var h := _make({"humans": 0b000011, "tuning": SHORT})
	h.add_client(0, 60, 5)
	var c := h.add_client(1, 60, 5)
	h.run_ms(8000)
	assert_eq(c.session.desyncs, 0)
	# Damage the confirmed copy, as a bug or a flipped bit would.
	c.session.rollback.confirmed.world.players[0].x += 3.0
	h.run_ms(3000)
	assert_eq(c.session.desyncs, 1, "the next CHECKSUM found it")
	assert_eq(c.session.resyncs, 1, "and a SNAPSHOT put it right")
	assert_eq(h.room().counters.get("snapshots", 0), 1)
	h.run_ms(3000)
	var last := c.session.rollback.confirmed_tick - 1
	for tick in range(last - 60, last):
		assert_eq(c.confirmed_hashes[tick], h.server_hashes[tick], "tick %d" % tick)


func test_predicting_only_when_needed_gives_the_same_state_as_rebuilding_every_frame() -> void:
	var lazy := _make({"humans": 0b001111, "tuning": SHORT, "track_hashes": false})
	var eager := _make({"humans": 0b001111, "tuning": SHORT, "track_hashes": false, "always_rebuild": true})
	for seat in 4:
		lazy.add_client(seat, 90 + seat * 20, 20)
		eager.add_client(seat, 90 + seat * 20, 20)
	var compared := 0
	for frame in 1500:
		lazy.step()
		eager.step()
		if frame % 25 == 0 and lazy.clients[0].session.has_match():
			for i in 4:
				var a := lazy.clients[i].session
				var b := eager.clients[i].session
				assert_eq(a.rollback.predicted_tick, b.rollback.predicted_tick, "frame %d" % frame)
				assert_eq(a.rollback.predicted.checksum(), b.rollback.predicted.checksum(), "seat %d at frame %d" % [i, frame])
				compared += 1
	assert_gt(compared, 100)


func test_sounds_come_once_per_predicted_tick_and_never_again_after_a_rollback() -> void:
	var h := _make({"humans": 0b000011, "tuning": SHORT, "track_hashes": false})
	h.add_client(0, 120, 20)
	var c := h.add_client(1, 120, 20)
	var heard: Dictionary = {}
	var twice := [0]
	c.session.on_predicted_tick = func(m: Match) -> void:
		var tick := m.world.tick
		if heard.has(tick):
			twice[0] += 1
		heard[tick] = true
	h.run_ms(20000)
	assert_gt(c.session.rollback.rebuilds, 5, "there were rollbacks")
	assert_eq(twice[0], 0, "and no tick was announced twice")
	assert_gt(heard.size(), 500)


func test_a_person_who_loses_the_connection_is_marked_as_having_left_and_gets_the_seat_back_if_they_return() -> void:
	var h := _make({"humans": 0b000111, "tuning": SHORT, "room": {"bot_after_ms": 400, "grace_ms": 30000}})
	h.add_client(0, 60, 10)
	h.add_client(1, 60, 10)
	var gone := h.add_client(2, 60, 10)
	h.run_ms(12000)
	var room := h.room()
	assert_eq(room.game.abandoned_mask, 0)
	gone.session.close()
	h.run_ms(3000)
	assert_eq(room.game.abandoned_mask, 0b100, "seat 2 counts as having left")
	assert_eq(room.stream_byte(room.tick - 1, 2), PlayerInput.BOT, "and its bot drives")
	h.reconnect(gone)
	h.run_ms(6000)
	var back: Harness.Client = h.clients.back()
	assert_eq(back.seat, 2)
	assert_eq(room.game.abandoned_mask, 0, "the seat is theirs again")
	assert_ne(room.stream_byte(room.tick - 1, 2), PlayerInput.BOT)
	assert_eq(back.session.resyncs, 1, "they came back with a snapshot")
	assert_eq(back.session.state, OnlineSession.State.PLAYING)
	var last := back.session.rollback.confirmed_tick - 1
	for tick in range(last - 120, last):
		assert_eq(back.confirmed_hashes[tick], h.server_hashes[tick], "tick %d" % tick)
	assert_eq(h.compare(h.clients[0])["mismatches"], 0, "the others never lost step")


func test_a_person_who_does_not_return_in_time_ends_the_match_as_last_with_the_abandonment_in_the_result() -> void:
	var h := _make({"humans": 0b000011, "tuning": {"race_finish_px": 1500.0, "match_races": 1}, "room": {"bot_after_ms": 400, "grace_ms": 3000}})
	h.add_client(0, 60, 10)
	var gone := h.add_client(1, 60, 10)
	h.run_ms(8000)
	gone.session.close()
	assert_true(h.run_until_over(300000))
	var result := h.room().result()
	assert_true(result["seats"][1]["abandoned"])
	assert_false(result["seats"][0]["abandoned"])
	assert_gt(result["seats"][1]["place"], result["seats"][0]["place"], "the one who left ranks below the one who stayed")
	var order := h.room().game.ranking_order()
	assert_eq(order.find(1), order.size() - 1, "last of all the cars, bots included")
	assert_eq(result["seats"][1]["steam_id"], "76561198000000001", "the id travels as text")
	h.run_ms(3000)
	assert_eq(h.compare(h.clients[0])["mismatches"], 0)


func test_the_clock_settles_ahead_of_the_server_and_inputs_arrive_in_time() -> void:
	var h := _make({"humans": 0b000011, "tuning": SHORT, "track_hashes": false})
	h.add_client(0, 150, 30)
	var c := h.add_client(1, 40, 5)
	h.run_ms(30000)
	var room := h.room()
	var late_before: int = room.counters.get("late_inputs", 0)
	h.run_ms(10000)
	var late_after: int = room.counters.get("late_inputs", 0)
	assert_lt(late_after - late_before, 30, "once settled almost no input is late")
	assert_between(c.session.rtt_ms, 70, 120)
	assert_between(c.session.speed_factor, 0.98, 1.02)
	assert_between(h.clients[0].session.rtt_ms, 290, 380)
