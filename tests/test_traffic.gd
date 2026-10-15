extends "res://tests/test_case.gd"
## Traffic rules (scripts/sim/traffic.gd and the traffic steps of world.gd): the 11 tests of the Phaser
## tests/traffic.test.ts (commit 0a0841f) in the six-lane profile, plus the plan's traffic tests
## (test_car_gap_floor, test_n1_traffic_screen_motion_matches_phaser, adjacent lane changes).
##
## Phaser moved traffic in screen y; the port moves it in world y and the screen y follows from the camera, so these
## tests read positions through World.screen_y().

const Config := preload("res://scripts/sim/config.gd")
const Rng := preload("res://scripts/sim/rng.gd")
const Traffic := preload("res://scripts/sim/traffic.gd")
const World := preload("res://scripts/sim/world.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")
const H := preload("res://tests/sim_helpers.gd")

const DT := Config.DT
const EPS := 1e-9

var std := Config.standard()
var phs := Config.phaser()


func test_lane_of_inverts_lane_x_for_every_lane() -> void:
	var wrong: Array = []
	for cfg: Config in [std, phs]:
		var widths: Array[float] = cfg.kind_w.duplicate()
		widths.append(cfg.player_w)
		for lane in cfg.lane_count:
			for width: float in widths:
				if Traffic.lane_of(cfg, Traffic.lane_x(cfg, lane, width), width) != lane:
					wrong.append([cfg.profile, lane, width])
	assert_eq(wrong, [])
	assert_eq(std.lane_count, 6)


func test_a_slower_car_drifts_down_the_screen() -> void:
	var w := H.quiet_world(std)
	var p := w.player()
	p.speed = 180.0
	var c := H.in_lane(w, Config.KIND_YELLOW, 0, 100.0, 80.0)
	H.run(w, H.ACCEL)
	assert_gt(w.screen_y(c.y_world), 100.0)
	assert_almost_eq(w.screen_y(c.y_world), 100.0 + (p.speed - 80.0) * Config.K * DT, EPS)


## Phaser: 200 km/h from y = -100 with the player stopped, gone after 1 s. Six lanes: from -100 x K = -56.25 it
## rises 1.875 px per tick; it leaves when its bottom is above -120 x K = -67.5, after 17 ticks.
func test_a_faster_car_drifts_up_and_leaves_the_top() -> void:
	var w := H.quiet_world(std)
	var c := H.in_lane(w, Config.KIND_YELLOW, 0, -100.0 * Config.K, 200.0)
	H.run(w, H.NONE)
	assert_almost_eq(w.screen_y(c.y_world), -56.25 - 1.875, EPS)
	H.run(w, H.NONE, 15)
	assert_not_null(H.find(w, c.id), "still there after 16 ticks")
	H.run(w, H.NONE)
	assert_null(H.find(w, c.id), "removed after 17 ticks")


func test_oil_moves_on_screen_only_while_the_player_moves() -> void:
	var w := H.quiet_world(std)
	var oil := H.in_lane(w, Config.KIND_OIL, 0, 300.0 * Config.K)
	H.run(w, H.NONE, 10)
	assert_eq(w.screen_y(oil.y_world), 168.75, "the player is stopped: it stays put")
	w.player().speed = 100.0
	H.run(w, H.NONE)
	assert_gt(w.screen_y(oil.y_world), 168.75, "the player moves: it drifts down")


func test_a_pass_is_paid_once_when_the_car_is_fully_behind() -> void:
	var w := H.quiet_world(std)
	var p := w.player()
	p.speed = 150.0
	var c := H.in_lane(w, Config.KIND_YELLOW, 0, w.anchor + p.h - 1.0)
	H.run(w, H.NONE)
	assert_true((w.events & World.EV_PASS) != 0)
	assert_eq(p.score, 50)
	assert_eq(c.passed_mask, 1)
	H.run(w, H.NONE)
	assert_eq(w.events & World.EV_PASS, 0, "no second payment")
	assert_eq(p.score, 50)


func test_oil_and_fuel_cars_never_count_as_passed() -> void:
	var w := H.quiet_world(std)
	var p := w.player()
	p.speed = 150.0
	var oil := H.in_lane(w, Config.KIND_OIL, 0, w.anchor + p.h - 1.0)
	var fuel_car := H.in_lane(w, Config.KIND_FUEL_CAR, 0, w.anchor + p.h - 1.0)
	H.run(w, H.NONE)
	assert_eq(w.events & World.EV_PASS, 0)
	assert_eq(p.score, 0)
	assert_eq([oil.passed_mask, fuel_car.passed_mask], [0, 0])


## Ten seconds after its timer runs out, a red car has changed lane once, to an adjacent lane, and settled there.
func test_a_red_car_changes_lane_exactly_once() -> void:
	var w := H.quiet_world(std, 3)
	var c := H.in_lane(w, Config.KIND_RED, 3, 150.0)
	c.lanes_left = 1
	c.lane_timer = 1
	H.run(w, H.NONE, 600)
	assert_eq(c.lanes_left, 0)
	var lane := Traffic.lane_of(std, c.x, c.w)
	assert_eq(absi(lane - 3), 1, "an adjacent lane")
	assert_eq(c.x, Traffic.lane_x(std, lane, c.w), "settled in it")
	assert_eq(c.target_lane, -1)


func test_nothing_spawns_while_the_road_stands_still() -> void:
	var w := World.new(std, 9)
	var gaps := [w.spawner.car_gap, w.spawner.oil_gap, w.spawner.fuel_gap]
	H.run(w, H.NONE, 600)
	assert_eq(w.traffic.size(), 0)
	assert_eq(w.spawner.next_id, 1)
	assert_eq([w.spawner.car_gap, w.spawner.oil_gap, w.spawner.fuel_gap], gaps)


## Phaser: about one car per 350 px of road (4 to 9 in 2100 px). Six lanes: one per 98.4375 px, the first after
## half a gap, so 2100 x K x 3/6 = 590.625 px of road holds exactly 6 cars at 100 and at 190 km/h.
func test_about_one_car_per_gap_of_road_at_any_speed() -> void:
	var distance := 2100.0 * Config.K * 3.0 / 6.0
	assert_eq(distance, 590.625)
	assert_eq([_cars_spawned_over(distance, 100.0), _cars_spawned_over(distance, 190.0)], [6, 6])


## Plan §6: car gaps never fall below 200 x K x 3/6 = 56.25 px, even at stage 50 (gap scale 0.9^49).
func test_car_gap_floor() -> void:
	var scale := 1.0
	for i in 49:
		scale *= Config.SPAWN_GAP_SCALE
	var rng := Rng.new(3)
	var smallest := INF
	for i in 200:
		smallest = minf(smallest, Traffic.next_gap(std, Config.GAP_CAR, scale, rng))
	assert_eq(smallest, 56.25)
	assert_eq(std.car_gap_min, 56.25)
	assert_eq(Traffic.next_gap(std, Config.GAP_CAR, 1.0, rng), 98.4375, "stage 1: 350 x K x 3/6")
	assert_eq(Traffic.next_gap(phs, Config.GAP_CAR, scale, rng), 200.0, "Phaser's floor")


func test_later_stages_have_shorter_gaps() -> void:
	for gap_kind: int in [Config.GAP_CAR, Config.GAP_OIL]:
		assert_lt(_average_gap(std, gap_kind, 0.81), _average_gap(std, gap_kind, 1.0), "gap kind %d" % gap_kind)


## Plan §6: with one seat, a traffic object moves on screen by (player km/h - its km/h) x K per second, as
## Phaser's `y += (playerKmh - kmh) * dt` did, while the player accelerates, brakes and coasts.
func test_n1_traffic_screen_motion_matches_phaser() -> void:
	for cfg: Config in [std, phs]:
		var w := H.quiet_world(cfg)
		var p := w.player()
		p.speed = 120.0
		var kmhs: Array[float] = [0.0, 60.0, 90.0, 120.0, 135.5, 200.0]
		var lanes: Array[int] = []
		for lane in cfg.lane_count:
			if lane != cfg.start_lane:
				lanes.append(lane)
		for i in kmhs.size():
			var top := cfg.view_height * (0.1 + 0.15 * float(i))
			H.in_lane(w, Config.KIND_YELLOW, lanes[i % lanes.size()], top, kmhs[i])
		var bytes: Array[int] = [H.ACCEL, H.ACCEL_HIGH, H.NONE, H.BRAKE, H.ACCEL_HIGH]
		var worst := 0.0
		var compared := 0
		for tick in 300:
			var before := {}
			for c: Traffic in w.traffic:
				before[c.id] = w.screen_y(c.y_world)
			H.run(w, bytes[floori(tick / 60.0)])
			for c: Traffic in w.traffic:
				if before.has(c.id):
					var expected: float = before[c.id] + (p.speed - c.kmh) * cfg.px_per_kmh * DT
					worst = maxf(worst, absf(w.screen_y(c.y_world) - expected))
					compared += 1
		assert_lt(worst, EPS, "largest difference, px, profile %d" % cfg.profile)
		assert_gt(compared, 500, "objects compared, profile %d" % cfg.profile)


## Plan §4: in the six-lane game a lane change goes to an adjacent lane. Phaser picked any other lane.
func test_lane_changes_go_to_an_adjacent_lane() -> void:
	assert_eq(_lane_jumps(std), [1], "six lanes")
	assert_eq(_lane_jumps(phs), [1, 2], "Phaser, three lanes")


## A blue car near the player heads for the player's lane: one lane at a time with six lanes, straight there in
## Phaser's profile. Far from the player it picks a lane at random.
func test_a_blue_car_heads_for_the_player() -> void:
	var w := H.quiet_world(std)
	var near := H.in_lane(w, Config.KIND_BLUE, 5, w.anchor - 50.0)
	near.lanes_left = 3
	near.lane_timer = 1
	H.run(w, H.NONE)
	assert_eq(near.target_lane, 4, "one lane toward lane 2")
	assert_eq(near.lanes_left, 2)

	var far_world := H.quiet_world(std, 8)
	var far := H.in_lane(far_world, Config.KIND_BLUE, 0, 0.0)
	far.lanes_left = 3
	far.lane_timer = 1
	H.run(far_world, H.NONE)
	assert_eq(far.target_lane, 1, "lane 0 can only go to lane 1")

	var pw := H.quiet_world(phs)
	var phaser_blue := H.in_lane(pw, Config.KIND_BLUE, 0, pw.anchor - 100.0)
	phaser_blue.lanes_left = 2
	phaser_blue.lane_timer = 1
	H.run(pw, H.NONE)
	assert_eq(phaser_blue.target_lane, phs.start_lane, "Phaser: the player's lane")


## New objects appear just above the screen (top at -h - 4 x K), in a lane with nothing near the top. With every
## lane busy, the spawn waits at gap 0 and is retried.
func test_spawns_use_a_free_lane_just_above_the_screen() -> void:
	var w := World.new(std, 4)
	for lane in 6:
		if lane != 4:
			H.in_lane(w, Config.KIND_YELLOW, lane, 10.0)
	w.spawner.car_gap = 0.0
	w.player().speed = 100.0
	H.run(w, H.NONE)
	var spawned := H.find(w, 1)
	assert_not_null(spawned)
	if spawned != null:
		assert_eq(Traffic.lane_of(std, spawned.x, spawned.w), 4, "the one free lane")
		assert_almost_eq(w.screen_y(spawned.y_world), -spawned.h - 2.25, EPS, "top at -h - 4 x K")
	w.spawner.car_gap = 0.0
	H.run(w, H.NONE)
	assert_eq(w.spawner.next_id, 2, "every lane busy: nothing new")
	assert_eq(w.spawner.car_gap, 0.0, "the gap waits at 0")


# --- helpers ---------------------------------------------------------------------------------------------------------


## Cars (not oil or fuel cars) spawned while the player covers `distance` at a steady speed, unharmed.
func _cars_spawned_over(distance: float, speed: float) -> int:
	var w := World.new(std, 11)
	var p := w.player()
	var seen := {}
	while p.y_world < distance:
		p.speed = speed
		p.invulnerable = 1000000
		H.run(w, H.NONE)
		for c: Traffic in w.traffic:
			if c.is_car():
				seen[c.id] = true
	return seen.size()


static func _average_gap(cfg: Config, gap_kind: int, scale: float) -> float:
	var rng := Rng.new(5)
	var total := 0.0
	for i in 500:
		total += Traffic.next_gap(cfg, gap_kind, scale, rng)
	return total / 500.0


## Sorted distances (in lanes) of the first lane change of red cars from every lane, over 40 seeds.
static func _lane_jumps(cfg: Config) -> Array:
	var jumps := {}
	for seed_value in 40:
		var lane := seed_value % cfg.lane_count
		var w := H.quiet_world(cfg, seed_value)
		var c := H.in_lane(w, Config.KIND_RED, lane, 20.0)
		c.lanes_left = 1
		c.lane_timer = 1
		H.run(w, H.NONE)
		jumps[absi(c.target_lane - lane)] = true
	var out := jumps.keys()
	out.sort()
	return out
