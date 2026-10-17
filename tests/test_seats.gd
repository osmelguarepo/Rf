extends "res://tests/test_case.gd"
## Seats: the N-player data model that phase B builds on (docs/GODOT_PLAN.md §3, §7), in the single-player mode's
## rules. One input byte per seat, 0xFF for a bot, per-seat bit masks on traffic, cars that pass through each other,
## and a camera on the leading live car. The versus rules (scoring, elimination, rounds, each seat's own RNG stream)
## are tested in tests/test_versus.gd, test_versus_round.gd and test_versus_rng.gd.

const Config := preload("res://scripts/sim/config.gd")
const Car := preload("res://scripts/sim/car.gd")
const Traffic := preload("res://scripts/sim/traffic.gd")
const World := preload("res://scripts/sim/world.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")
const H := preload("res://tests/sim_helpers.gd")

var std := Config.standard()


## Plan §6, narrowed as the lead's note after A1 asks: two seats fed the same bytes stay identical, tick after tick,
## through passes and bumps, while neither draws from an RNG. In this mode every seat's random events (oil-skid
## direction, roadside crash cost, centre-bump direction) draw from the one world RNG, in seat order, so the seats
## would part at the first draw. Here no draw is left to happen: each traffic car is off the seats' centre line (no
## bump direction to draw), there is no oil, and the seats steer into every skid (no roadside crash); the world RNG
## is checked to be untouched. The general case, seats that draw, is the versus mode's: each seat has its own
## stream, and tests/test_versus_rng.gd::test_traffic_same_for_2_and_6_seats checks that seats which draw leave the
## traffic and the other seats alone.
func test_two_players_same_inputs_identical_while_neither_draws() -> void:
	var w := H.quiet_world(std, 6, 2)
	var world_rng := w.rng.state
	var x := w.player().x
	H.add_traffic(w, Config.KIND_YELLOW, x + 5.0, 150.0, 60.0)
	H.add_traffic(w, Config.KIND_RED, x - 4.0, 20.0, 80.0)
	H.in_lane(w, Config.KIND_BLUE, 1, 40.0, 90.0)
	H.in_lane(w, Config.KIND_YELLOW, 4, 0.0, 100.0)
	var differing := 0
	var seen := [0, 0]
	for tick in 600:
		var into_slide := int(signf(w.players[0].slide_vx))
		H.run(w, PlayerInput.encode(true, false, into_slide, tick > 120))
		if not strict_equal(_seat_state(w.players[0]), _seat_state(w.players[1])):
			differing += 1
		seen[0] |= w.players[0].events
		seen[1] |= w.players[1].events
	assert_eq(differing, 0, "ticks where the two seats differed")
	assert_eq(w.rng.state, world_rng, "no seat drew from the world RNG, so the property applies")
	assert_eq(seen[0], seen[1])
	assert_true((seen[0] & World.EV_PASS) != 0, "both passed cars")
	assert_true((seen[0] & World.EV_BUMP) != 0, "both were bumped")
	assert_eq(w.players[0].score, w.players[1].score)
	assert_eq(w.camera_y, w.players[0].y_world, "the camera is on the pair")


## Plan §6: cars never touch each other. Two seats start on the same spot and part ways without a bump, skid or
## crash.
func test_players_never_collide() -> void:
	var w := H.quiet_world(std, 2, 3)
	var bad := 0
	for tick in 240:
		var steer_1 := 1 if tick < 60 else 0
		var steer_2 := -1 if tick < 60 else 0
		w.step(PackedByteArray([
			PlayerInput.encode(true, false, 0, false),
			PlayerInput.encode(true, false, steer_1, true),
			PlayerInput.encode(true, tick > 200, steer_2, false),
		]))
		for p: Car in w.players:
			if (p.events & (World.EV_BUMP | World.EV_SKID | World.EV_CRASH)) != 0 or p.slide_vx != 0.0:
				bad += 1
	assert_eq(bad, 0, "seat-ticks with a contact")
	assert_eq(w.phase, World.RUNNING)
	assert_gt(w.players[1].x - w.players[2].x, 40.0, "the seats did move apart")


## A pass is paid once per seat: the car's passed mask gets one bit per seat.
func test_each_seat_is_paid_once_for_a_pass() -> void:
	var w := H.quiet_world(std, 1, 2)
	for p: Car in w.players:
		p.speed = 150.0
	var c := H.in_lane(w, Config.KIND_YELLOW, 0, w.anchor + std.player_h - 1.0)
	H.run(w, H.NONE, 5)
	assert_eq([w.players[0].score, w.players[1].score], [50, 50])
	assert_eq(c.passed_mask, 0b11)


## Oil sends each seat into a skid once and stays on the road until every live seat has driven over it.
func test_oil_stays_until_every_live_seat_has_used_it() -> void:
	var w := H.quiet_world(std, 1, 2)
	var oil := H.on_car(w, Config.KIND_OIL)
	w.players[1].x = std.road_left
	w.step(PackedByteArray([H.NONE, H.NONE]))
	assert_eq(oil.consumed_mask, 0b01, "seat 0 used it")
	assert_not_null(H.find(w, oil.id), "seat 1 has not")
	w.players[1].x = w.players[0].x
	w.players[0].slide_vx = 0.0
	w.step(PackedByteArray([H.NONE, H.NONE]))
	assert_true((w.players[1].events & World.EV_SKID) != 0, "seat 1 skids")
	assert_eq(w.players[0].events & World.EV_SKID, 0, "seat 0 does not skid twice")
	assert_null(H.find(w, oil.id), "every seat used it: it is gone")


## A missing byte is no input; 0xFF hands the seat to a bot (no input until phase B's bot.gd).
func test_missing_and_bot_bytes_read_as_no_input() -> void:
	var w := H.quiet_world(std, 1, 3)
	for tick in 60:
		w.step(PackedByteArray([H.ACCEL, PlayerInput.BOT]))
	assert_gt(w.players[0].speed, 0.0, "seat 0 drove")
	assert_eq(w.players[1].speed, 0.0, "seat 1 is a bot")
	assert_eq(w.players[2].speed, 0.0, "seat 2 had no byte")


## Pause and confirm come from any seat that is not a bot; the bot byte has the pause bit set but never pauses.
func test_pause_comes_from_any_human_seat() -> void:
	var w := H.quiet_world(std, 1, 3)
	w.step(PackedByteArray([H.ACCEL, PlayerInput.BOT, H.ACCEL]))
	assert_eq(w.phase, World.RUNNING, "0xFF does not pause")
	w.step(PackedByteArray([H.ACCEL, PlayerInput.BOT, H.PAUSE]))
	assert_eq(w.phase, World.PAUSED, "seat 2 paused")
	w.step(PackedByteArray([H.PAUSE, PlayerInput.BOT, H.NONE]))
	assert_eq(w.phase, World.RUNNING, "seat 0 resumed")


## The camera follows the leading live car and never moves back, even when that car drops out.
func test_camera_follows_the_leading_live_seat() -> void:
	var w := H.quiet_world(std, 1, 2)
	H.run(w, H.ACCEL, 120)
	w.players[1].y_world += 40.0
	w.step(PackedByteArray([H.ACCEL, H.ACCEL]))
	assert_eq(w.camera_y, w.players[1].y_world, "seat 1 leads")
	assert_eq(w.screen_y(w.players[1].y_world), w.anchor)
	assert_gt(w.screen_y(w.players[0].y_world), w.anchor, "seat 0 is drawn lower")
	w.players[1].alive = 0
	var camera := w.camera_y
	w.step(PackedByteArray([H.ACCEL, H.ACCEL]))
	assert_eq(w.camera_y, camera, "the leader is out: the camera holds")
	for tick in 300:
		w.step(PackedByteArray([H.ACCEL, H.ACCEL]))
	assert_eq(w.camera_y, w.players[0].y_world, "seat 0 caught up and leads")
	assert_gt(w.camera_y, camera)


## A seat's car state without what differs between seats by design: its slot and its own RNG stream (seeded per
## seat, unused in this mode).
static func _seat_state(p: Car) -> Array:
	var a := p.to_array()
	a[0] = 0
	a[a.size() - 1] = 0
	return a
