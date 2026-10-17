extends "res://tests/test_case.gd"
## Versus mode and randomness (docs/GODOT_PLAN.md §3, §7; the lead's note for B1 after A1): every seat draws its own
## random events from its own stream, so seats and bots never shift the traffic's draws; and the versus state is
## complete and deterministic (to_array(), from_array(), clone(), checksum()).

const Config := preload("res://scripts/sim/config.gd")
const Rng := preload("res://scripts/sim/rng.gd")
const Car := preload("res://scripts/sim/car.gd")
const Traffic := preload("res://scripts/sim/traffic.gd")
const World := preload("res://scripts/sim/world.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")
const H := preload("res://tests/sim_helpers.gd")

const DT := Config.DT
const EPS := 1e-9
## mulberry32's state step per draw (scripts/sim/rng.gd).
const RNG_STEP := 0x6D2B79F5
## _scripted_step(): no round ended in the step.
const NOT_ENDED := -2

var std := Config.standard()


## In versus mode a seat's random events draw from its own stream (Car.rng), never from the world RNG that makes the
## traffic: an oil skid's direction, a roadside crash's fuel cost and a bump's direction when the centres line up,
## one draw each. Single player keeps Phaser's way: the same events draw from the world RNG.
func test_seat_draws_use_the_seats_own_stream() -> void:
	var w := H.quiet_versus(std, 15, 3, 0b111)
	var world_state := w.rng.state
	var streams: Array[Rng] = []
	for p: Car in w.players:
		streams.append(p.rng.clone())
	H.on_car(w, Config.KIND_RED, 0)
	H.on_car(w, Config.KIND_OIL, 1)
	var crash := w.players[2]
	crash.x = std.road_right - crash.w
	crash.slide_vx = std.skid_speed
	crash.speed = 100.0
	H.run(w, H.NONE)
	assert_eq(w.rng.state, world_state, "the world RNG did not move")
	var bump_direction := -1.0 if streams[0].next() < 0.5 else 1.0
	assert_true((w.players[0].events & World.EV_BUMP) != 0, "seat 0 was bumped centre on centre")
	assert_eq(w.players[0].slide_vx, bump_direction * std.skid_speed, "its direction: seat 0's stream")
	var skid_direction := -1.0 if streams[1].next() < 0.5 else 1.0
	assert_true((w.players[1].events & World.EV_SKID) != 0, "seat 1 skidded on oil")
	assert_eq(w.players[1].slide_vx, skid_direction * std.skid_speed, "its direction: seat 1's stream")
	var cost := streams[2].int_range(Config.CRASH_FUEL_MIN, Config.CRASH_FUEL_MAX)
	assert_true((crash.events & World.EV_CRASH) != 0, "seat 2 crashed into the roadside")
	assert_almost_eq(100.0 - DT - crash.fuel, float(cost), EPS, "its fuel cost: seat 2's stream")
	var states: Array = []
	var expected: Array = []
	for p: Car in w.players:
		states.append(p.rng.state)
		expected.append(streams[p.slot].state)
	assert_eq(states, expected, "one draw from each seat's own stream")

	var single := H.quiet_world(std, 15)
	var p := single.player()
	var own := p.rng.state
	var replica := single.rng.clone()
	H.on_car(single, Config.KIND_OIL)
	H.run(single, H.NONE)
	var direction := -1.0 if replica.next() < 0.5 else 1.0
	assert_eq(p.slide_vx, direction * std.skid_speed, "single player: the world RNG's draw, as Phaser")
	assert_eq([single.rng.state, p.rng.state], [replica.state, own], "and the seat's stream is untouched")


## The streams never overlap within a game. mulberry32 moves its state by 0x6D2B79F5 a draw, so every seed is on one
## cycle and a seed n x 0x6D2B79F5 further on is the same stream n draws later. World.seat_seed() adds
## (slot + 1) x Config.SEAT_SEED_STEP, and SEAT_SEED_STEP = 2^28 x 0x6D2B79F5 (mod 2^32): slot s's stream starts
## (s + 1) x 2^28 draws after the world's, so the world's and the six seats' are 268 435 456 draws apart.
func test_seat_streams_start_2_pow_28_draws_apart() -> void:
	assert_eq(Config.SEAT_SEED_STEP, ((1 << 28) * RNG_STEP) & 0xFFFFFFFF)
	var rng := Rng.new(123)
	for i in 1000:
		rng.next_u32()
	assert_eq(rng.state, (123 + 1000 * RNG_STEP) & 0xFFFFFFFF, "1000 draws move the state by 1000 steps")
	var wrong := 0
	for seed_value: int in [0, 1, 20261017, 0xFFFFFFFF]:
		for slot in Config.VERSUS_SEATS_MAX:
			var after_draws := (seed_value + (slot + 1) * (1 << 28) * RNG_STEP) & 0xFFFFFFFF
			if World.seat_seed(seed_value, slot) != after_draws:
				wrong += 1
	assert_eq(wrong, 0, "seat seeds that are not the world seed (slot + 1) x 2^28 draws on")
	var w := World.versus(std, 99, 6, 0b1)
	var seeds := {}
	for p: Car in w.players:
		seeds[p.rng.state] = true
	seeds[99] = true
	assert_eq(seeds.size(), 7, "seven different starting points")


## Adding seats does not change the traffic: two versus worlds from one seed, with 2 seats and with 6, seats 0 and 1
## driving the same way in both (invulnerable and fast, so they never fall back among the others). In the 6-seat
## world four bot seats with no input trail on the bottom edge, where traffic bumps them, oil spins them, the roadside
## costs them fuel (draws from their own streams), they take fuel cars and blue cars head their way. At every tick both
## worlds still have the same world RNG, camera and spawner, seats 0 and 1 are identical, and they spawn the same
## objects in the same places. One extra draw from the world RNG at the start would have changed the whole sequence.
## (The same with bots that drive: tests/test_bot.gd::test_traffic_does_not_depend_on_the_number_of_bots.)
func test_traffic_same_for_2_and_6_seats() -> void:
	var two := _pair_world(2)
	var six := _pair_world(6)
	var shifted := _pair_world(2)
	shifted.rng.next()
	var spawns_two: Array = []
	var spawns_six: Array = []
	var spawns_shifted: Array = []
	var differing := 0
	var trailing_events := 0
	for tick in 3600:
		two.step(_pair_bytes(two))
		six.step(_pair_bytes(six))
		shifted.step(_pair_bytes(shifted))
		_log_spawns(two, tick, spawns_two)
		_log_spawns(six, tick, spawns_six)
		_log_spawns(shifted, tick, spawns_shifted)
		if not strict_equal(_shared(two), _shared(six)):
			differing += 1
		for slot in range(2, 6):
			trailing_events |= six.players[slot].events
	assert_eq(differing, 0, "ticks where the world RNG, camera, spawner or seats 0 and 1 differed")
	assert_eq(spawns_six.size(), spawns_two.size(), "objects spawned")
	assert_eq(spawns_six, spawns_two, "the same objects, kinds, places, speeds and timers")
	assert_gt(spawns_two.size(), 100)
	assert_ne(spawns_shifted, spawns_two, "one extra world draw changes the traffic")
	var drew := 0
	for slot in range(2, 6):
		if six.players[slot].rng.state != World.seat_seed(six.game_seed, slot):
			drew += 1
	assert_gt(drew, 1, "trailing bots drew from their own streams")
	assert_eq(trailing_events & (World.EV_BUMP | World.EV_SKID), World.EV_BUMP | World.EV_SKID, "they were bumped and skidded")
	assert_eq([two.phase, six.phase], [World.RUNNING, World.RUNNING])


## The versus state is complete: a 6-seat game restored at tick 600 from to_array() (also through var_to_bytes, and
## from a clone()) runs 600 more ticks, with a pause and new rounds, to the same checksum as the one that never
## stopped.
func test_versus_restore_midway_same_checksum() -> void:
	var w := World.versus(std, 20261017, 6, 0b000111)
	var most_spawned := 0
	var rounds := 0
	for tick in 600:
		rounds += 0 if _scripted_step(w, tick) == NOT_ENDED else 1
		most_spawned = maxi(most_spawned, w.spawner.next_id - 1)
	var saved := w.to_array()
	var travelled: Array = bytes_to_var(var_to_bytes(saved))
	var copy := w.clone()
	for tick in range(600, 1200):
		rounds += 0 if _scripted_step(w, tick) == NOT_ENDED else 1
		most_spawned = maxi(most_spawned, w.spawner.next_id - 1)
	var restored := World.from_array(std, saved)
	var unpacked := World.from_array(std, travelled)
	for tick in range(600, 1200):
		_scripted_step(restored, tick)
		_scripted_step(unpacked, tick)
		_scripted_step(copy, tick)
	assert_eq(restored.checksum(), w.checksum(), "from to_array()")
	assert_eq(unpacked.checksum(), w.checksum(), "through var_to_bytes")
	assert_eq(copy.checksum(), w.checksum(), "from clone()")
	assert_eq([restored.mode, restored.anchor, restored.players.size()], [World.MODE_VERSUS, 192.0, 6])
	assert_gt(most_spawned, 10, "objects spawned in one round")
	assert_gt(rounds, 0, "a round ended and a new one started")


# --- helpers ---------------------------------------------------------------------------------------------------------


## A versus world for the 2-or-6 seats test: seats 0 and 1 human, in lanes 1 and 4 (the 2-seat start lanes) at
## 300 km/h and invulnerable for the whole run; seats 2 to 5 bots in lanes 0, 2, 3 and 5.
func _pair_world(seats: int) -> World:
	var w := World.versus(std, 4242, seats, 0b11)
	var lanes: Array[int] = [1, 4, 0, 2, 3, 5]
	for p: Car in w.players:
		p.x = Traffic.lane_x(std, lanes[p.slot], p.w)
		if p.slot < 2:
			p.speed = 300.0
			p.invulnerable = 1000000
	return w


## Seats 0 and 1: throttle in high gear, steering into any skid. Bot seats: no input (a bot given a byte is driven
## by it), so they stand in the traffic's way and draw from their own streams.
static func _pair_bytes(w: World) -> PackedByteArray:
	var bytes := PackedByteArray()
	for p: Car in w.players:
		if p.slot < 2:
			bytes.append(PlayerInput.encode(true, false, int(signf(p.slide_vx)), true))
		else:
			bytes.append(PlayerInput.NONE)
	return bytes


## What two worlds with the same traffic must share: world RNG, camera, spawner, and seats 0 and 1 whole.
static func _shared(w: World) -> Array:
	return [w.rng.state, w.camera_y, w.spawner.to_array(), w.players[0].to_array(), w.players[1].to_array()]


## Appends each object that spawned this tick (ids count up from 1): [tick, id, kind, x, y_world, kmh, lanes to
## change, lane timer].
static func _log_spawns(w: World, tick: int, spawns: Array) -> void:
	for c: Traffic in w.traffic:
		if c.id > spawns.size():
			spawns.append([tick, c.id, c.kind, c.x, c.y_world, c.kmh, c.lanes_left, c.lane_timer])


## One step of a scripted versus game: humans hold the throttle, high gear from 160 km/h, steer into skids and weave;
## bots 0xFF; seat 0 pauses at tick 300 and resumes at 360. A round that ends is followed by a new one
## (World.start_round()). Returns the winner of a round that ended in this step (World.NO_WINNER for none), or
## NOT_ENDED.
static func _scripted_step(w: World, tick: int) -> int:
	var bytes := PackedByteArray()
	for p: Car in w.players:
		if p.human == 0:
			bytes.append(PlayerInput.BOT)
			continue
		var steer := int(signf(p.slide_vx))
		if steer == 0:
			steer = [0, -1, 0, 1][(floori(tick / 45.0) + p.slot) % 4]
		var pause := p.slot == 0 and (tick == 300 or tick == 360)
		bytes.append(PlayerInput.encode(true, false, steer, p.speed >= 160.0, pause))
	w.step(bytes)
	if w.phase != World.ROUND_OVER:
		return NOT_ENDED
	var winner := w.winner
	w.start_round()
	return winner
