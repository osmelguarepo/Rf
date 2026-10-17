extends "res://tests/test_case.gd"
## The bots (scripts/sim/bot.gd; docs/GODOT_PLAN.md §7 "Bots"): their decisions in staged situations (the high gear
## rule, the lane they choose, skids, fuel cars, what they see), the 12-tick reaction, a 0xFF seat that drives on its
## own, takeovers, and the randomness they leave alone: the traffic does not depend on how many bots there are, and
## nothing is drawn while a round is paused.
##
## The staged tests call Bot.decide() on a quiet versus world: seat 1 is the bot, on the anchor line in the lane the
## test gives; seat 0 (human) is parked far behind, out of the way. decide() is the byte the bot wants now, before
## its reaction delay; next_byte() is the one that drives.

const Config := preload("res://scripts/sim/config.gd")
const Rng := preload("res://scripts/sim/rng.gd")
const Car := preload("res://scripts/sim/car.gd")
const Traffic := preload("res://scripts/sim/traffic.gd")
const World := preload("res://scripts/sim/world.gd")
const Bot := preload("res://scripts/sim/bot.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")
const H := preload("res://tests/sim_helpers.gd")

const BOT := PlayerInput.BOT
const DT := Config.DT
const REACTION := Config.BOT_REACTION_TICKS

var std := Config.standard()


## Plan §7: high gear from 160 km/h while 150 px ahead of the car are free (the gap from its front edge to the next
## obstacle's rear edge, in its own path); low gear otherwise. Traffic in another lane, and fuel cars, do not count.
func test_bot_high_gear_from_160_with_150_px_free() -> void:
	var w := _scene(2)
	var car := w.players[1]
	car.speed = 159.9
	assert_false(_high(w), "159.9 km/h, nothing ahead: low gear")
	car.speed = Config.BOT_HIGH_GEAR_KMH
	assert_true(_high(w), "160 km/h, nothing ahead: high gear")
	var yellow := _ahead(w, Config.KIND_YELLOW, 2, 149.0)
	assert_false(_high(w), "a car 149 px ahead")
	_move_to_gap(w, yellow, 151.0)
	assert_true(_high(w), "151 px ahead")
	_move_to_gap(w, yellow, 300.0)
	_ahead(w, Config.KIND_RED, 3, 40.0)
	_ahead(w, Config.KIND_FUEL_CAR, 2, 60.0)
	assert_true(_high(w), "a car in the next lane and a fuel car ahead do not count")
	var oil := _ahead(w, Config.KIND_OIL, 2, 100.0)
	assert_false(_high(w), "oil 100 px ahead")
	oil.x = Traffic.lane_x(std, 1, oil.w)
	var changing := _ahead(w, Config.KIND_RED, 3, 120.0)
	changing.target_lane = 2
	assert_false(_high(w), "a car 120 px ahead moving into the bot's lane")
	assert_eq(std.bot_free_ahead, 150.0)


## Plan §7: the bot heads for the clearest of its lane and the two next to it; the clearest is the one whose first
## obstacle is furthest away. It never heads two lanes away, and it changes lane only for a lane bot_lane_margin
## clearer than its own.
func test_bot_heads_for_the_clearest_adjacent_lane() -> void:
	var w := _scene(2)
	_ahead(w, Config.KIND_YELLOW, 2, 60.0)
	_ahead(w, Config.KIND_RED, 1, 100.0)
	assert_eq(_choice(w), [3, 1], "lane 3 is clear: head right")

	var left := _scene(2)
	_ahead(left, Config.KIND_YELLOW, 2, 60.0)
	_ahead(left, Config.KIND_YELLOW, 3, 90.0)
	_ahead(left, Config.KIND_YELLOW, 1, 120.0)
	assert_eq(_choice(left), [1, -1], "lane 1 is the clearest: head left")

	var boxed := _scene(2)
	for lane: int in [1, 2, 3]:
		_ahead(boxed, Config.KIND_YELLOW, lane, 40.0)
	assert_eq(_choice(boxed), [2, 0], "lanes 0 and 4 are clear but two lanes away: stay")

	var close := _scene(2)
	var near_car := _ahead(close, Config.KIND_YELLOW, 2, 150.0)
	assert_eq(_choice(close), [2, 0], "lane 3 is 18 px clearer: not enough (bot_lane_margin 24)")
	_move_to_gap(close, near_car, 140.0)
	assert_has([[1, -1], [3, 1]], _choice(close), "28 px clearer: change")
	assert_eq(std.bot_lane_margin, 24.0)


## A truck puts a car out; another car only bumps it, oil only spins it. So a lane with a truck within
## bot_truck_caution of the car ranks below one where a car is alongside, and of lanes with trucks, the one whose
## truck is furthest is best.
func test_bot_ranks_a_truck_below_any_bump() -> void:
	var w := _scene(2)
	_ahead(w, Config.KIND_TRUCK, 2, 150.0)
	_ahead(w, Config.KIND_RED, 1, -10.0)
	_ahead(w, Config.KIND_OIL, 3, 10.0)
	assert_eq(_choice(w), [3, 1], "into the oil 10 px ahead, not the car alongside, away from the truck 150 px ahead")

	var alongside := _scene(2)
	_ahead(alongside, Config.KIND_TRUCK, 2, 120.0)
	_ahead(alongside, Config.KIND_RED, 1, -10.0)
	_ahead(alongside, Config.KIND_RED, 3, -10.0)
	assert_has([1, 3], _choice(alongside)[0], "beside a car rather than toward the truck 120 px ahead")

	var trucks := _scene(2)
	_ahead(trucks, Config.KIND_TRUCK, 2, 100.0)
	_ahead(trucks, Config.KIND_TRUCK, 1, 160.0)
	_ahead(trucks, Config.KIND_TRUCK, 3, 120.0)
	assert_eq(_choice(trucks), [1, -1], "trucks everywhere: toward the furthest")
	assert_eq(std.bot_truck_caution, std.bot_look_ahead, "any truck in view ranks below every lane without one")


## Two neighbouring lanes equally clear: the bot's own RNG picks one (one draw), so different bots and different
## games go either way. A clear winner draws nothing.
func test_bot_breaks_lane_ties_with_its_own_rng() -> void:
	var picked := {}
	for seed_value in 12:
		var w := _scene(2, 100 + seed_value)
		_ahead(w, Config.KIND_YELLOW, 2, 30.0)
		var bot := w.bots[1]
		var replica := bot.rng.clone()
		var choice := _choice(w)
		assert_eq(choice[0], [1, 3][replica.pick_index(2)], "the draw picks the lane")
		assert_eq(bot.rng.state, replica.state, "one draw from the bot's own stream")
		picked[choice[0]] = true
	assert_eq(picked.size(), 2, "both sides were picked over 12 games")

	var clear_winner := _scene(2)
	_ahead(clear_winner, Config.KIND_YELLOW, 2, 30.0)
	_ahead(clear_winner, Config.KIND_YELLOW, 1, 60.0)
	var state := clear_winner.bots[1].rng.state
	var world_state := clear_winner.rng.state
	assert_eq(_choice(clear_winner), [3, 1])
	assert_eq([clear_winner.bots[1].rng.state, clear_winner.rng.state], [state, world_state], "no draw at all")


## Plan §7: the bot corrects a skid by steering into the slide, until the slide is over: it counts the corrections it
## has already decided and not yet made, so it stops in time and steers back to its lane.
func test_bot_steers_into_skids() -> void:
	var w := _scene(2)
	var car := w.players[1]
	car.speed = 200.0
	car.slide_vx = -std.skid_speed
	assert_eq(_steer(w), -1, "sliding left: steer left")
	car.slide_vx = std.skid_speed
	assert_eq(_steer(w), 1, "sliding right: steer right")
	# 12 corrections to the left are on their way; the slide (-50.625 px/s) needs 15: keep correcting.
	var bot := w.bots[1]
	car.slide_vx = -std.skid_speed
	_fill(bot, PlayerInput.encode(true, false, -1, false))
	assert_eq(_steer(w), -1, "3 more corrections needed")
	# A small slide (-10 px/s) is over after 3 of them; the 9 after it steer the car left of its lane: steer back.
	car.slide_vx = -10.0
	assert_eq(_steer(w), 1, "the slide will be over: back right, to the lane's centre")


## Plan §7: the bot chases a fuel car in its lane or the next one, up to bot_fuel_reach ahead, even past a car that
## would bump it, but not two lanes away, beyond reach, or with a truck in the way.
func test_bot_chases_fuel_cars_one_lane_away() -> void:
	var w := _scene(2)
	_ahead(w, Config.KIND_FUEL_CAR, 3, 80.0)
	assert_eq(_choice(w), [3, 1], "a fuel car one lane right")

	var two_away := _scene(2)
	_ahead(two_away, Config.KIND_FUEL_CAR, 4, 80.0)
	assert_eq(_choice(two_away), [2, 0], "two lanes away: not chased")

	var far := _scene(2)
	_ahead(far, Config.KIND_FUEL_CAR, 3, std.bot_fuel_reach + 5.0)
	assert_eq(_choice(far), [2, 0], "beyond reach")

	var truck := _scene(2)
	_ahead(truck, Config.KIND_FUEL_CAR, 3, 80.0)
	_ahead(truck, Config.KIND_TRUCK, 3, 20.0)
	assert_eq(_choice(truck)[0], 2, "a truck in the way")

	var bump := _scene(2)
	_ahead(bump, Config.KIND_FUEL_CAR, 1, 80.0)
	_ahead(bump, Config.KIND_YELLOW, 1, 20.0)
	assert_eq(_choice(bump), [1, -1], "past a car that would bump it")

	var own := _scene(2)
	_ahead(own, Config.KIND_FUEL_CAR, 2, 60.0)
	_ahead(own, Config.KIND_YELLOW, 2, 120.0)
	assert_eq(_choice(own), [2, 0], "in its own lane: it stays, though lanes 1 and 3 are clearer")

	# End to end: a bot at 200 km/h takes a fuel car 80 px ahead in the next lane.
	var drive := _scene(2)
	var car := drive.players[1]
	car.speed = 200.0
	car.fuel = 50.0
	_ahead(drive, Config.KIND_FUEL_CAR, 3, 80.0, Config.FUEL_CAR_SPEED)
	var steps := 0
	while car.score < Config.FUEL_CAR_POINTS and steps < 240:
		H.run_bytes(drive, [H.NONE, BOT])
		steps += 1
	assert_eq(car.score - floori(car.distance / 100.0) * 10, Config.FUEL_CAR_POINTS, "it took the fuel car")
	assert_gt(car.fuel, 55.0, "+10 fuel")


## Plan §7: the bot reacts 12 ticks late. next_byte() returns what the bot decided 12 calls before; the first 12
## calls of a round return Bot.START_BYTE (throttle, low gear, no steering). Here a skid starts at call 20: the bot
## decides to steer into it at once, and that byte comes out at call 32.
func test_bot_reacts_12_ticks_late() -> void:
	assert_eq(REACTION, 12)
	var w := _scene(2)
	var car := w.players[1]
	car.speed = 200.0
	var bot := w.bots[1]
	var sent: Array[int] = []
	var decided: Array[int] = []
	for call in 40:
		if call == 20:
			car.slide_vx = std.skid_speed
		sent.append(bot.next_byte(std, car, w.players, w.traffic, w.camera_y + w.anchor, call))
		decided.append(bot.pending[bot.pending.size() - 1])
	var wrong := 0
	for call in 40:
		var expected := Bot.START_BYTE if call < REACTION else decided[call - REACTION]
		if sent[call] != expected:
			wrong += 1
	assert_eq(wrong, 0, "calls whose byte was not the one decided 12 calls before")
	assert_eq(PlayerInput.steer_of(decided[20]), 1, "decided at once")
	assert_eq(PlayerInput.steer_of(sent[31]), 0)
	assert_eq(PlayerInput.steer_of(sent[32]), 1, "sent 12 calls later")
	assert_eq(bot.pending.size(), REACTION)


## The same through the world: a bot driving on an empty road starts to skid (as after a bump). It first sees the
## skid on the next step, and its first correction comes 12 steps after that one; 15 corrections later the skid is
## over (tests/test_car.gd::test_skid_recovers_in_15_steps), and the bot steers back to its lane.
func test_bot_corrects_a_skid_12_steps_after_it_sees_it() -> void:
	var w := _scene(2)
	var car := w.players[1]
	car.speed = 150.0
	H.run_bytes(w, [H.NONE, BOT], 30)
	var lane_x := Traffic.lane_x(std, 2, car.w)
	assert_eq(car.x, lane_x, "driving straight down its lane")
	car.slide_vx = std.skid_speed
	var slides: Array[float] = []
	for step in 120:
		H.run_bytes(w, [H.NONE, BOT])
		slides.append(car.slide_vx)
	var untouched := 0
	for step in REACTION:
		if slides[step] == std.skid_speed:
			untouched += 1
	assert_eq(untouched, REACTION, "steps 0 to 11 after it saw the skid: no correction yet")
	assert_almost_eq(slides[REACTION], std.skid_speed - std.correction_accel * DT, 1e-9, "the first, on step 12")
	assert_gt(slides[REACTION + 13], 0.0, "14 corrections are not enough")
	assert_eq(slides[REACTION + 14], 0.0, "the 15th ends the skid")
	assert_eq(car.events & World.EV_CRASH, 0)
	assert_almost_eq(car.x, lane_x, 1.5, "back on its lane's centre")


## Plan §7: bots always accelerate and never brake. Over a minute of six bots in traffic every byte decided has the
## throttle and no brake, and the gear rule is in use both ways.
func test_bot_always_accelerates() -> void:
	var w := World.versus(std, 33, 6, 0b000001)
	var bytes := PackedByteArray()
	bytes.resize(6)
	bytes.fill(BOT)
	var bad := 0
	var gears := {}
	for step in 3600:
		w.step(bytes)
		if w.phase != World.RUNNING:
			break
		for b: Bot in w.bots:
			var byte := b.pending[b.pending.size() - 1]
			if not PlayerInput.accel(byte) or PlayerInput.brake(byte):
				bad += 1
			gears[PlayerInput.high_gear(byte)] = true
	assert_eq(bad, 0, "bytes without the throttle, or with the brake")
	assert_eq(gears.size(), 2, "high gear and low gear both chosen")
	assert_true(PlayerInput.accel(Bot.START_BYTE) and not PlayerInput.brake(Bot.START_BYTE))


## A seat whose byte is 0xFF drives on its own: in 40 s of traffic the bot (and the human seat given 0xFF too, as
## after a disconnect) reaches high gear and high speed, changes lane, passes cars, stays clear of the bottom edge
## most of the time and is still in the round. A bot seat given no input instead is pushed along the bottom edge.
func test_bot_seat_drives_on_its_own() -> void:
	var w := World.versus(std, 41, 3, 0b001)
	var lanes: Array[Dictionary] = [{}, {}, {}]
	var top: Array[float] = [0.0, 0.0, 0.0]
	var high: Array[int] = [0, 0, 0]
	var passes: Array[int] = [0, 0, 0]
	var touching: Array[int] = [0, 0, 0]
	for step in 2400:
		H.run_bytes(w, [BOT, BOT, H.NONE])
		for p: Car in w.players:
			lanes[p.slot][Traffic.lane_of(std, p.x, p.w)] = true
			top[p.slot] = maxf(top[p.slot], p.speed)
			high[p.slot] += p.gear
			passes[p.slot] += 1 if (p.events & World.EV_PASS) != 0 else 0
			touching[p.slot] += p.touching_edge
	assert_eq(w.phase, World.RUNNING, "the round is still on")
	for seat in 2:
		var p := w.players[seat]
		assert_eq(p.alive, 1, "seat %d still in" % seat)
		assert_gt(top[seat], 380.0, "seat %d near the top speed" % seat)
		assert_gt(high[seat], 1200, "seat %d mostly in high gear" % seat)
		assert_gt(lanes[seat].size(), 2, "seat %d drove in several lanes" % seat)
		assert_gt(passes[seat], 20, "seat %d passed cars" % seat)
		assert_lt(touching[seat], 600, "seat %d mostly clear of the bottom edge" % seat)
		assert_gt(p.distance, 6000.0, "seat %d scored distance" % seat)
	assert_gt(touching[2], 600, "the seat with no input was pushed along the bottom edge until it went out")
	assert_eq(w.players[2].distance, 0.0, "and never scored distance")


## Plan §3, §7: each bot draws from its own stream, so the number of bots does not change the traffic. A human seat
## in lane 1 leads at 300 km/h and more, with 1 bot or with 5 behind it; the world RNG, the camera, the spawner and
## the human seat are the same at every tick for 30 s, and the same objects spawn in the same places. The bots drive
## (they change lane, and their streams move); one extra world draw would have changed everything. Every car is
## invulnerable, so the lone bot of the first world cannot go out and end its round (one human, no bot left).
func test_traffic_does_not_depend_on_the_number_of_bots() -> void:
	var one := _lead_world(2)
	var five := _lead_world(6)
	var shifted := _lead_world(2)
	shifted.rng.next()
	var spawns_one: Array = []
	var spawns_five: Array = []
	var spawns_shifted: Array = []
	var differing := 0
	var bot_lanes := {}
	for tick in 1800:
		one.step(_lead_bytes(one))
		five.step(_lead_bytes(five))
		shifted.step(_lead_bytes(shifted))
		_log_spawns(one, tick, spawns_one)
		_log_spawns(five, tick, spawns_five)
		_log_spawns(shifted, tick, spawns_shifted)
		if not strict_equal(_shared(one), _shared(five)):
			differing += 1
		for slot in range(1, 6):
			bot_lanes["%d:%d" % [slot, Traffic.lane_of(std, five.players[slot].x, std.player_w)]] = true
	assert_eq(differing, 0, "ticks where the world RNG, camera, spawner or the human seat differed")
	assert_eq(spawns_five, spawns_one, "the same objects, kinds, places, speeds and timers")
	assert_gt(spawns_one.size(), 60)
	assert_ne(spawns_shifted, spawns_one, "one extra world draw changes the traffic")
	var drew := 0
	for slot in range(1, 6):
		if five.bots[slot].rng.state != World.bot_seed(five.game_seed, slot):
			drew += 1
	assert_gt(drew, 0, "bots drew from their own streams")
	assert_gt(bot_lanes.size(), 10, "the bots drove in several lanes")
	assert_eq([one.phase, five.phase], [World.RUNNING, World.RUNNING])


## Plan §3: each bot has its own RNG, seeded from the game's seed and its seat: World.bot_seed(), the stream of slot
## + Config.BOT_STREAM_SLOT_OFFSET (6), so (slot + 7) x 2^28 draws along mulberry32's cycle from the world's stream:
## apart from the world's, the seats' (slots 0 to 5) and each other's. Single player has no bots.
func test_each_bot_has_its_own_stream() -> void:
	var w := World.versus(std, 808, 6, 0b000011)
	var starts := {808: "world"}
	var wrong := 0
	for p: Car in w.players:
		starts[p.rng.state] = "seat %d" % p.slot
		var bot := w.bots[p.slot]
		if bot.rng.state != World.bot_seed(808, p.slot) or bot.rng.state != World.seat_seed(808, p.slot + 6):
			wrong += 1
		starts[bot.rng.state] = "bot %d" % p.slot
	assert_eq(wrong, 0, "bots seeded with World.bot_seed()")
	assert_eq(starts.size(), 13, "the world, six seat streams and six bot streams all start apart")
	assert_eq(Config.BOT_STREAM_SLOT_OFFSET, Config.VERSUS_SEATS_MAX, "bot slots 6 to 11, after the seats' 0 to 5")
	var after := 7 * (1 << 28) * 0x6D2B79F5
	assert_eq(World.bot_seed(808, 0), (808 + after) & 0xFFFFFFFF, "bot 0: 7 x 2^28 draws on")
	assert_eq(World.new(std, 808, 2).bots.size(), 0, "single player: no bots")


## No bot runs while the round is paused: its state (stream, pending bytes, lane, clock) does not change, however
## long the pause, and it carries on afterwards without a takeover.
func test_bots_never_draw_while_paused() -> void:
	var w := World.versus(std, 52, 4, 0b0001)
	var bytes: Array = [BOT, BOT, BOT, BOT]
	H.run_bytes(w, bytes, 300)
	H.run_bytes(w, [H.PAUSE, BOT, BOT, BOT])
	assert_eq(w.phase, World.PAUSED)
	var before := _bot_states(w)
	H.run_bytes(w, bytes, 600)
	assert_eq(_bot_states(w), before, "nothing moved in 600 paused steps")
	var pending_before: Array = []
	for b: Bot in w.bots:
		pending_before.append(b.pending.duplicate())
	H.run_bytes(w, [H.PAUSE, BOT, BOT, BOT])
	assert_eq(w.phase, World.RUNNING)
	assert_eq(_bot_states(w), before, "nor on the step that resumed")
	H.run_bytes(w, bytes)
	var carried := 0
	for i in w.bots.size():
		if strict_equal(w.bots[i].pending.slice(0, REACTION - 1), pending_before[i].slice(1)):
			carried += 1
	assert_eq(carried, 4, "each bot went on with its own pending bytes: no takeover")


## A human seat whose controller goes away (0xFF) is driven by its bot. The bot takes the car over as it is: for its
## reaction time the car keeps the throttle and its gear, without steering, then the bot drives. When the controller
## is back, its bytes drive the car; if it goes away again, the bot takes over again, with nothing left from before.
func test_bot_takes_over_a_disconnected_human_seat() -> void:
	var w := World.versus(std, 63, 2, 0b11)
	var car := w.players[0]
	for step in 300:
		H.run_bytes(w, [PlayerInput.encode(true, false, 0, car.speed >= 160.0), BOT])
	assert_eq(car.gear, Car.GEAR_HIGH)
	var x := car.x
	var steps_held := 0
	for step in REACTION:
		H.run_bytes(w, [BOT, BOT])
		if car.gear == Car.GEAR_HIGH and car.x == x and car.slide_vx == 0.0:
			steps_held += 1
	assert_eq(steps_held, REACTION, "for 12 steps the car held its gear and its line")
	var bot := w.bots[0]
	assert_eq(bot.last_tick, w.stage_ticks - 1, "the bot drives the seat")
	H.run_bytes(w, [BOT, BOT], 200)
	assert_eq([car.human, car.alive, w.phase], [1, 1, World.RUNNING], "still a human seat")
	var speed := car.speed
	H.run_bytes(w, [H.BRAKE, BOT], 30)
	assert_almost_eq(car.speed, speed - 30.0 * Config.BRAKE * DT, 1e-6, "back: its own brake drives it")
	H.run_bytes(w, [BOT, BOT])
	var hold := PlayerInput.encode(true, false, 0, false)
	assert_eq(bot.pending.slice(0, REACTION - 1), [hold, hold, hold, hold, hold, hold, hold, hold, hold, hold, hold],
		"taken over again: the throttle and its gear (low, after braking), nothing stale")


## A bot sees what a player sees: an object above the top of the screen does not count until it comes into view.
## It leaves out what can no longer touch its seat: a car that already bumped it, oil it already drove over.
func test_bot_sees_only_the_screen_and_what_can_still_touch_it() -> void:
	var w := _scene(2)
	var truck := _ahead(w, Config.KIND_TRUCK, 2, 193.0)
	assert_eq(_choice(w), [2, 0], "the truck's rear edge 1 px above the screen: not seen")
	_move_to_gap(w, truck, 191.0)
	assert_has([[1, -1], [3, 1]], _choice(w), "1 px into view: seen, and avoided")
	# The same through the world, whose hook passes the top of the screen (camera_y + anchor): nothing moves here.
	var hooked := _scene(2)
	var hidden := _ahead(hooked, Config.KIND_TRUCK, 2, 193.0)
	H.run_bytes(hooked, [H.NONE, BOT])
	assert_eq(hooked.bots[1].lane, 2, "through the world: not seen above the screen")
	_move_to_gap(hooked, hidden, 191.0)
	H.run_bytes(hooked, [H.NONE, BOT])
	assert_has([1, 3], hooked.bots[1].lane, "through the world: seen once in view")

	var bumped := _scene(2)
	var car := _ahead(bumped, Config.KIND_YELLOW, 2, 20.0)
	car.struck_mask = 0b10
	assert_eq(_choice(bumped), [2, 0], "a car that already bumped this seat")
	car.struck_mask = 0b01
	assert_has([[1, -1], [3, 1]], _choice(bumped), "one that bumped another seat still can")

	var oiled := _scene(2)
	var oil := _ahead(oiled, Config.KIND_OIL, 2, 20.0)
	oil.consumed_mask = 0b10
	assert_eq(_choice(oiled), [2, 0], "oil this seat already drove over")
	oil.consumed_mask = 0b01
	assert_has([[1, -1], [3, 1]], _choice(oiled), "oil only another seat used")


## Cars pass through each other, but a bot gives way to another car just ahead of it, or level with it and of a
## lower seat: two bots on one spot part, the higher seat moving to a clear lane. Two bots that start on one spot
## drive apart and stay apart most of the time.
func test_bots_give_way_to_the_car_ahead() -> void:
	var w := H.quiet_versus(std, 70, 3, 0b001)
	w.players[0].y_world = -1000.0
	for seat: int in [1, 2]:
		H.place(w, seat, Traffic.lane_x(std, 2, std.player_w), 192.0)
	assert_eq(_choice_of(w, 1), [2, 0], "the lower seat keeps its lane")
	assert_has([[1, -1], [3, 1]], _choice_of(w, 2), "the higher seat gives way")
	H.place(w, 2, w.players[2].x, 192.0 - 10.0)
	w.bots[1].lane = -1
	w.bots[2].lane = -1
	assert_has([[1, -1], [3, 1]], _choice_of(w, 1), "seat 1, now 10 px behind, gives way")
	assert_eq(_choice_of(w, 2), [2, 0], "seat 2, ahead, keeps its lane")

	var drive := H.quiet_versus(std, 71, 3, 0b001)
	for seat: int in [1, 2]:
		H.place(drive, seat, Traffic.lane_x(std, 2, std.player_w), 192.0)
	var together := 0
	for step in 600:
		H.run_bytes(drive, [H.ACCEL, BOT, BOT])
		var a := drive.players[1]
		var b := drive.players[2]
		if absf(a.x - b.x) < a.w and absf(a.y_world - b.y_world) < a.h:
			together += 1
	assert_lt(together, 60, "steps the two bots overlapped")


# --- helpers ---------------------------------------------------------------------------------------------------------


## A quiet versus world for staged decisions: seat 1 (the bot) on the anchor line in `lane`, seat 0 parked far behind
## in lane 5.
func _scene(lane: int, seed_value: int = 90) -> World:
	var w := H.quiet_versus(std, seed_value, 2, 0b01)
	w.players[0].x = Traffic.lane_x(std, 5, std.player_w)
	w.players[0].y_world = -1000.0
	H.place(w, 1, Traffic.lane_x(std, lane, std.player_w), 192.0)
	return w


## Adds a standing object of a kind centred in a lane, its rear edge `gap` px ahead of the bot car's front edge.
func _ahead(w: World, kind: int, lane: int, gap: float, kmh: float = 0.0) -> Traffic:
	var car := w.players[1]
	var c := H.in_lane(w, kind, lane, 0.0, kmh)
	c.y_world = car.y_world + gap + c.h
	return c


func _move_to_gap(w: World, c: Traffic, gap: float) -> void:
	c.y_world = w.players[1].y_world + gap + c.h


## The bot's decision for seat 1 now: [the lane it heads for, its steering].
func _choice(w: World) -> Array:
	return _choice_of(w, 1)


func _choice_of(w: World, seat: int) -> Array:
	var byte := w.bots[seat].decide(std, w.players[seat], w.players, w.traffic, w.camera_y + w.anchor)
	return [w.bots[seat].lane, PlayerInput.steer_of(byte)]


func _steer(w: World) -> int:
	return _choice(w)[1]


func _high(w: World) -> bool:
	return PlayerInput.high_gear(w.bots[1].decide(std, w.players[1], w.players, w.traffic, w.camera_y + w.anchor))


static func _fill(bot: Bot, byte: int) -> void:
	for i in bot.pending.size():
		bot.pending[i] = byte


## Every bot's state, as to_array() writes it.
static func _bot_states(w: World) -> Array:
	var out: Array = []
	for b: Bot in w.bots:
		out.append(b.to_array())
	return out


## A world for the bot-count test: seat 0 human in lane 1 at 300 km/h (so it always leads); the bots behind it in
## their start lanes. Every car is invulnerable for the whole run: traffic never slows seat 0, and no bot goes out.
func _lead_world(seats: int) -> World:
	var w := World.versus(std, 4343, seats, 0b1)
	for p: Car in w.players:
		p.invulnerable = 1000000
	var lead := w.players[0]
	lead.x = Traffic.lane_x(std, 1, lead.w)
	lead.speed = 300.0
	return w


## Seat 0: throttle in high gear, steering into any skid. The bots: 0xFF.
static func _lead_bytes(w: World) -> PackedByteArray:
	var bytes := PackedByteArray()
	for p: Car in w.players:
		bytes.append(PlayerInput.encode(true, false, int(signf(p.slide_vx)), true) if p.slot == 0 else BOT)
	return bytes


## What two worlds with the same traffic must share: world RNG, camera, spawner, and seat 0 whole.
static func _shared(w: World) -> Array:
	return [w.rng.state, w.camera_y, w.spawner.to_array(), w.players[0].to_array()]


## Appends each object that spawned this tick (ids count up from 1): [tick, id, kind, x, y_world, kmh, lanes to
## change, lane timer].
static func _log_spawns(w: World, tick: int, spawns: Array) -> void:
	for c: Traffic in w.traffic:
		if c.id > spawns.size():
			spawns.append([tick, c.id, c.kind, c.x, c.y_world, c.kmh, c.lanes_left, c.lane_timer])
