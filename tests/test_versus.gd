extends "res://tests/test_case.gd"
## Versus rules, part 1 (docs/GODOT_PLAN.md §7 and §8 B1; World.MODE_VERSUS in scripts/sim/world.gd): the versus
## world, the camera, the bottom edge, contacts, points and the traffic getting denser. tests/test_versus_round.gd
## has eliminations, the end of a round, winners, pause and the bot hook; tests/test_versus_rng.gd the seats' own
## RNG streams, the traffic they leave alone, and the state.

const Config := preload("res://scripts/sim/config.gd")
const Rng := preload("res://scripts/sim/rng.gd")
const Car := preload("res://scripts/sim/car.gd")
const Traffic := preload("res://scripts/sim/traffic.gd")
const World := preload("res://scripts/sim/world.gd")
const Collision := preload("res://scripts/sim/collision.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")
const H := preload("res://tests/sim_helpers.gd")

const DT := Config.DT
const EPS := 1e-9
## Events no contact between two players may cause.
const CONTACT_EVENTS := World.EV_BUMP | World.EV_SKID | World.EV_CRASH | World.EV_SPIN

var std := Config.standard()


## World.versus(): 2 to 6 seats in distinct lanes spread over the road (Config.VERSUS_START_LANES, seat i in lane
## floor((i + 0.5) x 6 / seats)), every car on the anchor line y = 192 with a full tank, the human flags as given,
## each seat's own stream seeded from the game's seed, no goal, running.
func test_versus_world_starts_in_spread_lanes_on_the_anchor_line() -> void:
	assert_eq(Config.VERSUS_START_LANES.slice(2), [[1, 4], [1, 3, 5], [0, 2, 3, 5], [0, 1, 3, 4, 5], [0, 1, 2, 3, 4, 5]])
	for seats in range(2, 7):
		var w := World.versus(std, 31, seats, 0b1)
		var lanes: Array = []
		var spread: Array = []
		var problems: Array = []
		for p: Car in w.players:
			var lane := Traffic.lane_of(std, p.x, p.w)
			lanes.append(lane)
			spread.append(floori((p.slot + 0.5) * 6.0 / seats))
			if p.x != Traffic.lane_x(std, lane, p.w) or w.screen_y(p.y_world) != 192.0:
				problems.append("seat %d not centred in its lane on the anchor line" % p.slot)
			if not strict_equal([p.fuel, p.score, p.speed, p.alive, p.distance, p.touching_edge], [100.0, 0, 0.0, 1, 0.0, 0]):
				problems.append("seat %d does not start fresh" % p.slot)
			if p.human != (1 if p.slot == 0 else 0):
				problems.append("seat %d human flag %d" % [p.slot, p.human])
			if p.rng.state != World.seat_seed(31, p.slot):
				problems.append("seat %d stream" % p.slot)
		var distinct := {}
		for lane: int in lanes:
			distinct[lane] = true
		assert_eq(lanes, Config.VERSUS_START_LANES[seats], "%d seats" % seats)
		assert_eq(lanes, spread, "%d seats: the middle of each seat's share of the road" % seats)
		assert_eq(distinct.size(), seats, "%d seats: distinct lanes" % seats)
		assert_eq(problems, [])
		assert_eq([w.mode, w.phase, w.anchor, w.goal, w.camera_y, w.winner], [World.MODE_VERSUS, World.RUNNING, 192.0, 0.0, 0.0, World.NO_WINNER])
		assert_eq([w.gap_scale, w.stage_ticks, w.game_seed], [1.0, 0, 31])
		assert_eq(w.rng.state, (31 + 3 * 0x6D2B79F5) & 0xFFFFFFFF, "three world-RNG draws: the spawner's gaps")


## Two to six cars, at least one of them human, and only the standard profile.
func test_versus_needs_2_to_6_seats_and_a_human() -> void:
	assert_true(World.versus_valid(std, 2, 0b01), "one human, one bot")
	assert_true(World.versus_valid(std, 2, 0b11), "two humans")
	assert_true(World.versus_valid(std, 6, 0b100000), "one human in the last seat, five bots")
	assert_true(World.versus_valid(std, 6, 0b111111), "six humans")
	assert_false(World.versus_valid(std, 1, 0b1), "one car")
	assert_false(World.versus_valid(std, 7, 0b1), "seven cars")
	assert_false(World.versus_valid(std, 3, 0), "bots only")
	assert_false(World.versus_valid(std, 3, 0b1000), "a human bit past the last seat")
	assert_false(World.versus_valid(Config.phaser(), 2, 0b1), "the phaser profile has no versus mode")
	var w := World.versus(std, 1, 4, 0b0101)
	var humans: Array = []
	for p: Car in w.players:
		humans.append(p.human)
	assert_eq(humans, [1, 0, 1, 0])


## The camera follows the live car furthest ahead, human or bot, and that car's front edge is on the anchor line,
## y = 192. A car that goes out no longer counts: the camera holds where it left until a live car reaches that line,
## then follows that car.
func test_camera_follows_leading_alive_car() -> void:
	var w := H.quiet_versus(std, 1, 3, 0b001)
	var bot := w.players[2]
	bot.speed = 150.0
	var bytes: Array = [H.ACCEL, H.ACCEL, H.ACCEL]
	var off_line := 0
	for tick in 60:
		H.run_bytes(w, bytes)
		if w.camera_y != bot.y_world or w.screen_y(bot.y_world) != 192.0:
			off_line += 1
	assert_eq(off_line, 0, "ticks where the leading bot was not on the anchor line")
	assert_gt(w.screen_y(w.players[0].y_world), 192.0, "the human behind is drawn lower")

	bot.fuel = 0.001
	H.run_bytes(w, bytes)
	assert_eq([bot.alive, w.phase], [0, World.RUNNING], "the bot is out; the round goes on")
	var held := w.camera_y
	assert_eq(held, bot.y_world, "the camera stopped where the bot left")
	var holding := 0
	var following := 0
	var wrong := 0
	for tick in 300:
		H.run_bytes(w, bytes)
		var lead := maxf(w.players[0].y_world, w.players[1].y_world)
		if lead <= held:
			holding += 1
			if w.camera_y != held:
				wrong += 1
		else:
			following += 1
			if w.camera_y != w.players[0].y_world or w.screen_y(w.players[0].y_world) != 192.0:
				wrong += 1
	assert_eq(wrong, 0, "ticks off the rule")
	assert_gt(holding, 10, "the camera held while every live car was behind")
	assert_gt(following, 10, "then it followed the human seat that reached the line (seat 0, lowest of a tie)")
	assert_eq(bot.y_world, held, "the bot that left stays where it was")


## The camera never moves back, whatever the cars do: seats brake in turn, the lead changes hands, the leading bot
## goes out. Whenever a car that was live when the camera moved is past the camera's last position, the camera is on
## the furthest one. (The camera moves before the step's eliminations: a car that goes out leads its last step.)
func test_camera_monotonic() -> void:
	var w := H.quiet_versus(std, 2, 4, 0b0011)
	var last := w.camera_y
	var went_back := 0
	var off_leader := 0
	var holds := 0
	var changes := 0
	var leader := -1
	var leader_left := false
	for tick in 1500:
		if tick == 900:
			var first := _furthest(w, _live(w))
			if first.human == 0:
				first.fuel = 0.001
				leader_left = true
		var bytes := PackedByteArray()
		for p: Car in w.players:
			# Seat s brakes for 2 s in turn; odd seats change to high gear at 160 km/h.
			var braking := floori(tick / 120.0) % 4 == p.slot
			var high := p.slot % 2 == 1 and p.speed >= 160.0
			bytes.append(H.BRAKE if braking else (H.ACCEL_HIGH if high else H.ACCEL))
		var live := _live(w)
		w.step(bytes)
		var front := _furthest(w, live)
		if w.camera_y < last:
			went_back += 1
		if front.y_world > last:
			if w.camera_y != front.y_world or w.screen_y(front.y_world) != 192.0:
				off_leader += 1
			if front.slot != leader:
				changes += 1
				leader = front.slot
		else:
			holds += 1
			if w.camera_y != last:
				off_leader += 1
		last = w.camera_y
	assert_eq(went_back, 0, "ticks where the camera moved back")
	assert_eq(off_leader, 0, "ticks where the camera was not on the leading live car or held")
	assert_true(leader_left, "the leading car at tick 900 was a bot, and it went out")
	assert_eq(_live(w).size(), 3)
	assert_gt(changes, 3, "the lead changed hands")
	assert_gt(holds, 0, "the camera held while every live car was behind it")
	assert_eq(w.phase, World.RUNNING)


## A car left behind is held with its bottom edge on y = 352: each step it is put back there and its speed becomes at
## least the camera's speed (camera moved / (K x dt)), so it keeps up and can still steer. While it touches the edge
## it loses 1 + 2 = 3 fuel a second and earns no distance. A bottom edge from 351.5 down also touches, without being
## held.
func test_bottom_edge_clamps_and_drains_fuel() -> void:
	var w := H.quiet_versus(std, 3, 2, 0b11)
	var front := w.players[0]
	var back := w.players[1]
	front.speed = 190.0
	var bytes: Array = [H.ACCEL, H.NONE]
	var ticks := 0
	while back.touching_edge == 0 and ticks < 300:
		H.run_bytes(w, bytes)
		ticks += 1
	assert_eq(back.touching_edge, 1, "seat 1 reached the edge")
	assert_between(ticks, 60, 90, "after about 136 px of camera travel")

	var off_edge := 0
	var slower := 0
	var drain_wrong := 0
	var distance := back.distance
	for tick in 120:
		var fuel_before := back.fuel
		var camera_before := w.camera_y
		H.run_bytes(w, bytes)
		var camera_speed := (w.camera_y - camera_before) / (std.px_per_kmh * DT)
		if absf(w.screen_y(back.y_world) + back.h - 352.0) > EPS or back.touching_edge != 1:
			off_edge += 1
		if back.speed != camera_speed:
			slower += 1
		if absf((fuel_before - back.fuel) - 3.0 * DT) > EPS:
			drain_wrong += 1
	assert_eq(off_edge, 0, "ticks the car was not held on y = 352")
	assert_eq(slower, 0, "ticks the held car was not given the camera's speed")
	assert_eq(drain_wrong, 0, "ticks the touching car did not lose 3 fuel a second")
	assert_eq(back.distance, distance, "no distance while touching")
	assert_gt(back.speed, 190.0, "it moves at the camera's speed")

	# It can still steer: right, at the steering rate of its speed.
	var x := back.x
	var speed := Car.step_speed(back.speed, Car.GEAR_LOW, false, false)
	H.run_bytes(w, [H.ACCEL, H.RIGHT])
	assert_almost_eq(back.x - x, Car.steer_rate(std, speed) * DT, EPS, "steering while held")
	assert_gt(back.x - x, 1.0)

	# With every car stopped the camera stays: a bottom edge at 351.4 does not touch, one at 351.6 does.
	var still := H.quiet_versus(std, 3, 2, 0b11)
	var p := H.place(still, 1, still.players[1].x, 351.4 - 24.0)
	H.run(still, H.NONE)
	assert_eq(p.touching_edge, 0, "bottom edge at 351.4")
	assert_almost_eq(p.fuel, 100.0 - DT, EPS, "only the normal drain")
	H.place(still, 1, p.x, 351.6 - 24.0)
	var fuel := p.fuel
	H.run(still, H.NONE)
	assert_eq(p.touching_edge, 1, "bottom edge at 351.6")
	assert_almost_eq(still.screen_y(p.y_world) + p.h, 351.6, EPS, "not held: it did not move")
	assert_almost_eq(fuel - p.fuel, 3.0 * DT, EPS, "the extra drain")


## Cars pass through each other: two seats that start on one spot drive apart, then one drives through the other,
## and they never bump, skid or crash, and drive exactly as they do in separate lanes. Traffic still bumps each of
## them, once per seat.
func test_players_pass_through() -> void:
	var w := H.quiet_versus(std, 4, 2, 0b11)
	var apart := H.quiet_versus(std, 4, 2, 0b11)
	H.place(w, 1, w.players[0].x, 192.0)
	for world: World in [w, apart]:
		world.players[1].speed = 40.0
	var overlapping := 0
	var contacts := 0
	var differing := 0
	for tick in 300:
		var second := H.BRAKE if tick >= 180 else H.ACCEL
		H.run_bytes(w, [H.ACCEL, second])
		H.run_bytes(apart, [H.ACCEL, second])
		var a := w.players[0]
		var b := w.players[1]
		if Collision.overlaps(a.x, -a.y_world, a.w, a.h, b.x, -b.y_world, b.w, b.h):
			overlapping += 1
		for p: Car in w.players:
			if (p.events & CONTACT_EVENTS) != 0 or p.slide_vx != 0.0:
				contacts += 1
		for seat in 2:
			var here := w.players[seat]
			var there := apart.players[seat]
			if not strict_equal([here.y_world, here.speed, here.fuel, here.score, here.distance, here.events],
					[there.y_world, there.speed, there.fuel, there.score, there.distance, there.events]):
				differing += 1
	assert_gt(overlapping, 20, "ticks the two cars overlapped")
	assert_eq(contacts, 0, "seat-ticks with a contact between the players")
	assert_eq(differing, 0, "seat-ticks that differ from the same cars driving apart")
	assert_eq(w.players[0].x, apart.players[0].x, "nobody was pushed sideways")
	assert_gt(w.players[0].y_world, w.players[1].y_world, "seat 0 drove through seat 1 when it braked")

	# A small car over both seats on one spot bumps each of them, once per seat.
	var t := H.quiet_versus(std, 4, 2, 0b11)
	var seat_0 := t.players[0]
	H.place(t, 1, seat_0.x, 192.0)
	var small := H.add_traffic(t, Config.KIND_YELLOW, seat_0.x + 4.0, 194.0)
	H.run(t, H.NONE)
	assert_eq(small.struck_mask, 0b11, "struck both seats")
	for p: Car in t.players:
		assert_true((p.events & World.EV_BUMP) != 0, "seat %d bumped" % p.slot)
		assert_eq(p.slide_vx, -std.skid_speed, "seat %d pushed left, away from the car's centre" % p.slot)
		p.invulnerable = 0
		p.slide_vx = 0.0
		p.x = seat_0.x
	H.run(t, H.NONE)
	assert_eq(t.events & World.EV_BUMP, 0, "no second bump for either seat")


## An oil patch spins each car once and stays on the road until every live car has driven over it. A car that goes
## out stops counting: the patch leaves in the step the last car that had not used it goes out.
func test_oil_stays_until_every_live_car_has_used_it() -> void:
	var w := H.quiet_versus(std, 16, 3, 0b011)
	var x := w.players[0].x
	var oil := H.on_car(w, Config.KIND_OIL, 0)
	H.run(w, H.NONE)
	assert_eq(oil.consumed_mask, 0b001)
	assert_true((w.players[0].events & World.EV_SKID) != 0, "seat 0 skids")
	assert_not_null(H.find(w, oil.id), "seats 1 and 2 have not used it")
	H.place(w, 1, x, 192.0)
	H.run(w, H.NONE)
	assert_eq(oil.consumed_mask, 0b011)
	assert_eq([w.players[0].events & World.EV_SKID, w.players[1].events & World.EV_SKID], [0, World.EV_SKID],
		"seat 1 skids; seat 0, still on it, does not again")
	assert_not_null(H.find(w, oil.id), "the bot has not used it")
	w.players[2].fuel = 0.001
	H.run(w, H.NONE)
	assert_eq([w.players[2].alive, w.phase], [0, World.RUNNING])
	assert_null(H.find(w, oil.id), "every car still in the round has used it: it leaves")


## A blue car that changes lane heads for the live seat nearest it in y (centre to centre) within reach, the lowest
## seat on a tie; it ignores seats that are out or out of reach. Versus draws its random lane even then, so the world
## RNG moves the same whatever the seats do.
func test_blue_targets_nearest_alive_player() -> void:
	# Seats in lanes 0, 1, 5 and 2 at distances 30, 20, 10 and 100 from a blue car in lane 3. Seat 2 (lane 5) is
	# the nearest: one lane right. The first seat in reach would be seat 0: one lane left.
	var nearest := _blue_scene([-30.0, -20.0, -10.0, -100.0], 0b0000)
	assert_eq(nearest[0], 4, "toward seat 2, the nearest")
	assert_eq(nearest[1], 2, "one lane change used")
	assert_true(nearest[2], "the random lane was drawn as well")
	# Seat 2 is out: seat 1 (lane 1) is the nearest live seat.
	assert_eq(_blue_scene([-30.0, -20.0, -10.0, -100.0], 0b0100)[0], 2, "toward seat 1: seat 2 is out")
	# Seats 1 and 2 are both 20 away, one behind and one ahead: the lower seat, 1.
	assert_eq(_blue_scene([-30.0, -20.0, 20.0, -100.0], 0b0000)[0], 2, "a tie goes to the lower seat")
	# Every seat out of reach (the blue car 150 px ahead of the furthest): a random adjacent lane, from the draw.
	var far := _blue_scene([0.0, -20.0, -10.0, -100.0], 0b0000, 150.0)
	assert_eq(far[0], far[3], "the drawn lane")
	assert_has([2, 4], far[0])


## A passed car pays 50 to each seat once: three seats pass the same standing car in one step and each gets 50 for
## it, never more. A seat that passes a car while it touches the bottom edge uses the pass up and gets nothing.
func test_pass_50_once_per_player() -> void:
	var w := H.quiet_versus(std, 5, 3, 0b111)
	for p: Car in w.players:
		p.speed = 150.0
	var c := H.in_lane(w, Config.KIND_YELLOW, 0, w.anchor + std.player_h - 1.0)
	H.run(w, H.NONE)
	assert_eq(c.passed_mask, 0b111)
	assert_eq(_scores(w), [50, 50, 50])
	for p: Car in w.players:
		assert_true((p.events & World.EV_PASS) != 0, "seat %d pass event" % p.slot)
	H.run(w, H.NONE, 30)
	assert_eq(_scores(w), [50, 50, 50], "paid once; under 100 px driven, so no distance points either")

	var e := H.quiet_versus(std, 5, 2, 0b11)
	var front := e.players[0]
	var back := e.players[1]
	front.speed = 190.0
	H.place(e, 1, back.x, 352.0 - std.player_h)
	var standing := H.in_lane(e, Config.KIND_YELLOW, 2, 300.0)
	var touching := 0
	var paid_back := 0
	for tick in 40:
		H.run(e, H.ACCEL)
		touching += back.touching_edge
		paid_back += 1 if (back.events & World.EV_PASS) != 0 else 0
	assert_eq(touching, 40, "seat 1 touched the edge all along")
	assert_eq(standing.passed_mask, 0b11, "both seats passed it")
	assert_eq([front.score, back.score, paid_back], [50, 0, 0], "only the seat off the edge was paid")


## A fuel car is the first toucher's. When several seats touch it in the same step it goes to the one whose centre is
## nearest its centre, the lowest seat on a tie: +10 fuel and +1000 points for that seat, nothing for the others, and
## it leaves the road.
func test_rainbow_first_toucher_only() -> void:
	# Seats 0 and 2 both touch it; seat 2's centre is 2 px from its centre, seat 0's 6 px.
	var w := H.quiet_versus(std, 7, 3, 0b111)
	var fuel_car := H.in_lane(w, Config.KIND_FUEL_CAR, 2, 192.0)
	H.place(w, 0, fuel_car.x - 6.0, 192.0)
	H.place(w, 2, fuel_car.x + 2.0, 192.0)
	for p: Car in w.players:
		p.fuel = 50.0
	H.run(w, H.NONE)
	assert_eq(_scores(w), [0, 0, 1000], "the nearest centre, though seat 0 comes first")
	assert_almost_eq(w.players[2].fuel, 60.0 - DT, EPS)
	assert_almost_eq(w.players[0].fuel, 50.0 - DT, EPS, "nothing for seat 0")
	assert_eq(fuel_car.consumed_mask, 0b100)
	assert_null(H.find(w, fuel_car.id), "it left the road")
	assert_eq([w.players[0].events & World.EV_PICKUP, w.players[2].events & World.EV_PICKUP], [0, World.EV_PICKUP])

	# A tie: seats 0 and 2 both 4 px from its centre. The lower seat takes it.
	var tie := H.quiet_versus(std, 7, 3, 0b111)
	var tied_car := H.in_lane(tie, Config.KIND_FUEL_CAR, 2, 192.0)
	H.place(tie, 0, tied_car.x - 4.0, 192.0)
	H.place(tie, 2, tied_car.x + 4.0, 192.0)
	H.run(tie, H.NONE)
	assert_eq(_scores(tie), [1000, 0, 0], "a tie goes to the lower seat")

	# Seat 1 touches it first; seat 0 arrives on the same spot a step later and gets nothing.
	var first := H.quiet_versus(std, 7, 3, 0b111)
	var taken := H.on_car(first, Config.KIND_FUEL_CAR, 1)
	H.run(first, H.NONE)
	H.place(first, 0, first.players[1].x, 192.0)
	H.run(first, H.NONE)
	assert_eq(_scores(first), [0, 1000, 0], "the first to touch it")
	assert_eq(taken.consumed_mask, 0b010)


## Distance points: +10 for every 100 px of world a car drives, counted as speed x K x dt each step, only while it does
## not touch the bottom edge.
func test_distance_10_per_100px() -> void:
	var w := H.quiet_versus(std, 8, 2, 0b11)
	var lead := w.players[0]
	var slow := w.players[1]
	lead.speed = 198.0
	slow.speed = 100.0
	var expected := 0.0
	var wrong := 0
	var touching_ticks := 0
	var touching_growth := 0
	for tick in 600:
		var scroll := lead.speed * std.px_per_kmh * DT
		var slow_distance := slow.distance
		H.run_bytes(w, [H.ACCEL, H.NONE])
		expected += scroll
		if lead.distance != expected or lead.score != floori(lead.distance / 100.0) * 10:
			wrong += 1
		if slow.touching_edge != 0:
			touching_ticks += 1
			if slow.distance != slow_distance:
				touching_growth += 1
	assert_eq(lead.speed, 198.0, "the top of low gear, held with the throttle")
	assert_eq(wrong, 0, "ticks where the leader's distance or points were off")
	assert_almost_eq(lead.distance, 600.0 * 198.0 * Config.K / 60.0, 1e-9, "1113.75 px")
	assert_eq(lead.score, 110)
	assert_gt(touching_ticks, 100, "the slow car was held on the edge")
	assert_eq(touching_growth, 0, "no distance while touching")
	assert_eq(slow.score, floori(slow.distance / 100.0) * 10)
	assert_lt(slow.distance, slow.y_world, "being pushed is not distance")


## Every 1200 running ticks (20 s) the car and oil gaps shrink by 10 %: gap_scale is the running product of 0.9, and
## paused steps do not count. A new car or oil gap is (gap + jitter) x gap_scale, never under 40 px: the car gap,
## 98.4375 px at first, reaches the floor after 9 shrinks (180 s).
func test_gaps_shrink_10pct_per_1200_ticks_floor() -> void:
	var w := H.quiet_versus(std, 10, 2, 0b11)
	H.run(w, H.ACCEL, 1199)
	assert_eq([w.stage_ticks, w.gap_scale], [1199, 1.0])
	H.run(w, H.ACCEL)
	assert_eq([w.stage_ticks, w.gap_scale], [1200, 0.9], "the first shrink at 20 s")
	H.run(w, H.PAUSE)
	H.run(w, H.ACCEL, 600)
	H.run(w, H.PAUSE)
	assert_eq([w.phase, w.stage_ticks, w.gap_scale], [World.RUNNING, 1200, 0.9], "paused steps do not count")
	H.run(w, H.ACCEL, 1199)
	assert_eq(w.gap_scale, 0.9)
	H.run(w, H.ACCEL)
	assert_eq([w.stage_ticks, w.gap_scale], [2400, 0.9 * 0.9], "a product, not 1 - 0.1 x shrinks")

	var scale := 1.0
	var car_gaps: Array = []
	var wrong := 0
	for shrinks in 13:
		car_gaps.append(World.versus_gap(std, Config.GAP_CAR, scale, Rng.new(40 + shrinks)))
		if car_gaps[shrinks] != maxf(98.4375 * scale, 40.0):
			wrong += 1
		var rng := Rng.new(60 + shrinks)
		var replica := rng.clone()
		var oil := World.versus_gap(std, Config.GAP_OIL, scale, rng)
		if oil != maxf((1125.0 + replica.float_range(-281.25, 281.25)) * scale, 40.0):
			wrong += 1
		scale *= Config.VERSUS_GAP_SHRINK
	assert_eq(wrong, 0, "gaps off (gap + jitter) x scale, floored at 40")
	assert_eq(car_gaps[0], 98.4375, "350 x K x 3/6 at first")
	assert_gt(car_gaps[8], 40.0, "8 shrinks: 42.4 px")
	assert_eq(car_gaps.slice(9), [40.0, 40.0, 40.0, 40.0], "from 9 shrinks (180 s) on: the 40 px floor")
	var tiny := 1.0
	for i in 40:
		tiny *= Config.VERSUS_GAP_SHRINK
	assert_eq(World.versus_gap(std, Config.GAP_OIL, tiny, Rng.new(3)), 40.0, "oil gaps floor at 40 too")

	# The world's spawner uses them: every car stopped, so the gap left after a spawn is the new gap itself.
	var s := H.quiet_versus(std, 12, 2, 0b11)
	s.gap_scale = 0.9
	s.spawner.car_gap = 0.0
	H.run(s, H.NONE)
	assert_eq([s.traffic.size(), s.spawner.car_gap], [1, 98.4375 * 0.9], "a car spawned; the next gap is scaled")
	var floor_scale := 1.0
	for i in 9:
		floor_scale *= Config.VERSUS_GAP_SHRINK
	s.gap_scale = floor_scale
	s.spawner.car_gap = 0.0
	H.run(s, H.NONE)
	assert_eq([s.traffic.size(), s.spawner.car_gap], [2, 40.0], "the next gap at the floor")


## Fuel-car gaps never shrink: at any gap_scale a new fuel-car gap is the starting one, 4500 +- 1125 px, from the same
## draw. A round 60 s on (three shrinks) still spawns fuel cars that far apart, while its car gaps are 27 % shorter.
func test_rainbow_gaps_fixed() -> void:
	var scale := 1.0
	var wrong := 0
	for shrinks in 40:
		var rng := Rng.new(100 + shrinks)
		var replica := rng.clone()
		if World.versus_gap(std, Config.GAP_FUEL, scale, rng) != Traffic.next_gap(std, Config.GAP_FUEL, 1.0, replica):
			wrong += 1
		scale *= Config.VERSUS_GAP_SHRINK
	assert_eq(wrong, 0, "fuel-car gaps that depended on the scale")

	var w := H.quiet_versus(std, 13, 2, 0b11)
	H.run(w, H.ACCEL, 3600)
	assert_eq(w.gap_scale, 0.9 * 0.9 * 0.9, "three shrinks in 60 s")
	for p: Car in w.players:
		p.speed = 0.0
	w.spawner.car_gap = 0.0
	w.spawner.fuel_gap = 0.0
	H.run(w, H.NONE)
	var kinds: Array = []
	for c: Traffic in w.traffic:
		kinds.append(c.kind == Config.KIND_FUEL_CAR)
	assert_has(kinds, true, "a fuel car spawned")
	assert_between(w.spawner.fuel_gap, 3375.0, 5625.0, "its next gap: 4500 +- 1125, unscaled")
	assert_eq(w.spawner.car_gap, 98.4375 * w.gap_scale, "while the car gap is scaled: 71.8 px")


# --- helpers ---------------------------------------------------------------------------------------------------------


## Of the given seats, the car furthest ahead, the lowest seat on a tie (the camera's choice among live cars).
static func _furthest(w: World, seats: Array) -> Car:
	var best: Car = null
	for seat: int in seats:
		var p := w.players[seat]
		if best == null or p.y_world > best.y_world:
			best = p
	return best


## The seats still in the round.
static func _live(w: World) -> Array:
	var out: Array = []
	for p: Car in w.players:
		if p.alive != 0:
			out.append(p.slot)
	return out


static func _scores(w: World) -> Array:
	var out: Array = []
	for p: Car in w.players:
		out.append(p.score)
	return out


## A blue car in lane 3, its front at world y `blue_y`, about to change lane, and four stopped seats (seat 0 human)
## in lanes 0, 1, 5 and 2 with their fronts at `seat_y`; seats in `out_mask` are out. One step. Returns [the lane it
## heads for, lane changes left, whether the step drew the random lane (two world-RNG draws: lane and timer), the
## random lane the draw gave].
func _blue_scene(seat_y: Array, out_mask: int, blue_y: float = 0.0) -> Array:
	var w := H.quiet_versus(std, 14, 4, 0b0001)
	var lanes: Array[int] = [0, 1, 5, 2]
	for p: Car in w.players:
		p.x = Traffic.lane_x(std, lanes[p.slot], p.w)
		p.y_world = seat_y[p.slot]
		p.alive = 0 if (out_mask & (1 << p.slot)) != 0 else 1
	var blue := H.in_lane(w, Config.KIND_BLUE, 3, w.anchor - blue_y)
	blue.lanes_left = 3
	blue.lane_timer = 1
	var replica := w.rng.clone()
	var drawn: int = [2, 4][replica.pick_index(2)]
	replica.next()
	H.run(w, H.NONE)
	return [blue.target_lane, blue.lanes_left, w.rng.state == replica.state, drawn]
