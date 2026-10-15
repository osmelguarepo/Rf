extends "res://tests/test_case.gd"
## World rules (scripts/sim/world.gd): the 16 tests of the Phaser tests/state.test.ts (commit 0a0841f) in the
## six-lane profile, with distances x K, plus stage goals x K. tests/PARITY.md maps each Phaser test here.
##
## Phaser's onPlayer() put a traffic object exactly on the player; sim_helpers.gd on_car() does the same with the
## profile's own sizes (the small yellow car is 10x20 here).

const Config := preload("res://scripts/sim/config.gd")
const Car := preload("res://scripts/sim/car.gd")
const Traffic := preload("res://scripts/sim/traffic.gd")
const World := preload("res://scripts/sim/world.gd")
const Fuel := preload("res://scripts/sim/fuel.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")
const H := preload("res://tests/sim_helpers.gd")

const DT := Config.DT
const EPS := 1e-9

var std := Config.standard()


func test_a_new_world_starts_running_with_a_full_tank_and_the_first_goal() -> void:
	var w := World.new(std, 42)
	var p := w.player()
	assert_eq(w.phase, World.RUNNING)
	assert_eq(w.stage, 1)
	assert_eq(p.fuel, Config.FUEL_MAX)
	assert_eq(p.y_world, 0.0, "distance")
	assert_eq(w.goal, 13500.0, "24 000 x K")
	assert_eq(p.x, Traffic.lane_x(std, 2, std.player_w), "lane 2")
	assert_eq(p.x, 291.0)
	assert_eq([w.tick, w.camera_y, w.anchor, w.game_seed], [0, 0.0, 292.0, 42])


func test_pause_toggles_and_nothing_moves_while_paused() -> void:
	var w := World.new(std, 1)
	H.run(w, H.ACCEL)
	H.run(w, H.PAUSE | PlayerInput.ACCEL)
	assert_eq(w.phase, World.PAUSED)
	assert_eq(w.events, World.EV_PAUSE)
	var p := w.player()
	var frozen := [p.y_world, p.fuel, p.speed, w.stage_ticks, w.traffic.size(), w.rng.state, w.camera_y]
	H.run(w, H.ACCEL, 120)
	assert_eq(w.phase, World.PAUSED)
	assert_eq([p.y_world, p.fuel, p.speed, w.stage_ticks, w.traffic.size(), w.rng.state, w.camera_y], frozen)
	H.run(w, H.PAUSE)
	assert_eq(w.phase, World.RUNNING)
	assert_eq(w.events, World.EV_RESUME)


func test_an_empty_tank_ends_the_run() -> void:
	var w := H.quiet_world(std)
	w.player().fuel = 0.001
	w.player().speed = 100.0
	H.run(w, H.NONE)
	assert_eq(w.phase, World.GAME_OVER)
	assert_true((w.events & World.EV_GAME_OVER) != 0)
	var y := w.player().y_world
	H.run(w, H.ACCEL, 10)
	assert_eq([w.phase, w.events, w.player().y_world], [World.GAME_OVER, 0, y], "nothing moves after it")


## Phaser stepped once with dt = 1 s; here 60 ticks.
func test_fuel_drains_while_stopped() -> void:
	var w := World.new(std, 1)
	H.run(w, H.NONE, 60)
	assert_almost_eq(w.player().fuel, 99.0, EPS)
	assert_eq(w.player().speed, 0.0)
	assert_eq(w.player().y_world, 0.0)


func test_touching_a_truck_ends_the_run() -> void:
	var w := H.quiet_world(std)
	H.on_car(w, Config.KIND_TRUCK)
	H.run(w, H.NONE)
	assert_eq(w.phase, World.GAME_OVER)
	assert_true((w.events & World.EV_GAME_OVER) != 0)


## A small yellow car over the right half of the player: the bump pushes left. Speed and fuel are kept.
func test_a_bump_costs_no_fuel_or_speed_and_skids_away() -> void:
	var w := H.quiet_world(std)
	var p := w.player()
	p.speed = 150.0
	H.add_traffic(w, Config.KIND_YELLOW, p.x + 7.0, w.anchor + 2.0)
	H.run(w, H.ACCEL)
	assert_true((w.events & World.EV_BUMP) != 0, "bump")
	assert_eq(w.events & World.EV_CRASH, 0, "no crash")
	assert_almost_eq(p.fuel, 100.0 - DT, EPS, "only the normal drain")
	assert_gt(p.speed, 149.0)
	assert_almost_eq(p.speed, 150.0 + 70.0 * DT, EPS, "the throttle still works")
	assert_eq(p.slide_vx, -50.625, "a skid to the left, 90 x K px/s")
	assert_eq(p.invulnerable, Config.INVULNERABLE_TICKS)
	assert_eq(w.phase, World.RUNNING)


func test_the_same_traffic_car_cannot_bump_twice() -> void:
	var w := H.quiet_world(std)
	var c := H.on_car(w, Config.KIND_YELLOW)
	H.run(w, H.NONE)
	assert_true((w.events & World.EV_BUMP) != 0, "first contact")
	assert_eq(c.struck_mask, 1, "struck, for seat 0")
	w.player().invulnerable = 0
	w.player().slide_vx = 0.0
	H.run(w, H.NONE)
	assert_eq(w.events & World.EV_BUMP, 0, "no second bump, even after invulnerability")


func test_a_bump_during_invulnerability_is_ignored_and_does_not_strike() -> void:
	var w := H.quiet_world(std)
	w.player().invulnerable = 60
	var c := H.on_car(w, Config.KIND_YELLOW)
	H.run(w, H.NONE)
	assert_eq(w.events & World.EV_BUMP, 0)
	assert_eq(c.struck_mask, 0)


## Phaser: x = 60 sliding at -90 px/s. Six lanes: x = 188 sliding at -50.625 px/s.
func test_a_roadside_crash_costs_5_or_6_fuel_and_70_percent_of_the_speed() -> void:
	var w := H.quiet_world(std)
	var p := w.player()
	p.x = std.road_left
	p.speed = 100.0
	p.slide_vx = -std.skid_speed
	H.run(w, H.NONE)
	assert_true((w.events & World.EV_SPIN) != 0, "spin")
	assert_true((w.events & World.EV_CRASH) != 0, "crash")
	var cost := 100.0 - DT - p.fuel
	assert_true(absf(cost - 5.0) < EPS or absf(cost - 6.0) < EPS, "cost %s" % cost)
	assert_almost_eq(p.speed, (100.0 - 25.0 * DT) * 0.3, EPS, "x 0.3 after this tick's drag")
	assert_eq(p.invulnerable, Config.INVULNERABLE_TICKS - 1, "counting down from this tick")
	assert_eq(w.phase, World.RUNNING)


func test_oil_starts_a_skid_exactly_once() -> void:
	var w := H.quiet_world(std, 5)
	H.on_car(w, Config.KIND_OIL)
	H.run(w, H.NONE)
	assert_true((w.events & World.EV_SKID) != 0)
	assert_ne(w.player().slide_vx, 0.0)
	assert_eq(w.traffic.size(), 0, "the patch is used up")
	H.on_car(w, Config.KIND_OIL)
	H.run(w, H.NONE)
	assert_eq(w.events & World.EV_SKID, 0, "no new skid while skidding")


func test_a_fuel_car_refills_10_and_pays_1000() -> void:
	var w := H.quiet_world(std)
	w.player().fuel = 50.0
	H.on_car(w, Config.KIND_FUEL_CAR)
	H.run(w, H.NONE)
	assert_true((w.events & World.EV_PICKUP) != 0)
	assert_eq(w.player().score, 1000)
	assert_almost_eq(w.player().fuel, 60.0 - DT, EPS)
	assert_eq(w.traffic.size(), 0, "the fuel car leaves the road")


## A standing car in lane 0, its top 0.1 px above the player's rear edge: one tick at 100 km/h passes it.
func test_passing_a_car_scores_50() -> void:
	var w := H.quiet_world(std)
	var p := w.player()
	p.speed = 100.0
	H.in_lane(w, Config.KIND_YELLOW, 0, w.anchor + p.h - 0.1)
	H.run(w, H.NONE)
	assert_true((w.events & World.EV_PASS) != 0)
	assert_eq(p.score, 50)


## 0.001 px before the goal with 40.9 fuel: stage clear and floor(40.9 - 1/60) x 30 = 1200 points.
func test_reaching_the_goal_clears_the_stage_with_30_per_fuel_unit() -> void:
	var w := H.quiet_world(std)
	var p := w.player()
	p.y_world = w.goal - 0.001
	w.camera_y = p.y_world
	p.speed = 100.0
	p.fuel = 40.9
	H.run(w, H.NONE)
	assert_eq(w.phase, World.STAGE_CLEAR)
	assert_true((w.events & World.EV_STAGE_CLEAR) != 0)
	assert_eq(p.score, floori(40.9 - DT) * 30)
	assert_eq(p.score, 1200)
	assert_eq(w.high_score, 1200)


func test_confirm_at_stage_clear_starts_stage_2() -> void:
	var w := H.quiet_world(std)
	var p := w.player()
	w.phase = World.STAGE_CLEAR
	H.on_car(w, Config.KIND_YELLOW)
	p.fuel = 12.0
	p.y_world = 500.0
	w.camera_y = 500.0
	p.speed = 120.0
	p.score = 700
	H.run(w, H.CONFIRM)
	assert_eq(w.phase, World.RUNNING)
	assert_eq(w.stage, 2)
	assert_eq(w.goal, 15750.0, "28 000 x K")
	assert_eq([p.y_world, w.camera_y], [0.0, 0.0], "distance and camera restart")
	assert_eq(w.traffic.size(), 0, "empty road")
	assert_eq(p.fuel, Config.FUEL_MAX)
	assert_almost_eq(w.gap_scale, 0.9, 1e-15)
	assert_eq([p.speed, p.score, w.stage_ticks], [120.0, 700, 0], "speed and score carry over")


## Plan §6 test_stage_goals_times_k_loop: 24 000, 28 000, 32 000, 36 000, then 24 000 again, x K.
func test_stage_goals_times_k_loop() -> void:
	var goals: Array = []
	var phaser_goals: Array = []
	for stage: int in [1, 2, 3, 4, 5, 8, 9]:
		goals.append(std.stage_goal(stage))
		phaser_goals.append(Config.phaser().stage_goal(stage))
	assert_eq(goals, [13500.0, 15750.0, 18000.0, 20250.0, 13500.0, 20250.0, 13500.0])
	assert_eq(phaser_goals, [24000.0, 28000.0, 32000.0, 36000.0, 24000.0, 36000.0, 24000.0])
	var w := H.quiet_world(std)
	for stage: int in [2, 3, 4, 5]:
		w.phase = World.STAGE_CLEAR
		H.run(w, H.CONFIRM)
		assert_eq(w.goal, std.stage_goal(stage), "world goal at stage %d" % stage)


## 40 s of throttle with steering that cycles left, none, right every 90 ticks, twice from the same seed.
func test_the_same_seed_and_inputs_give_the_same_game() -> void:
	var a := _scripted(2024, 40 * 60)
	var b := _scripted(2024, 40 * 60)
	assert_eq(a.checksum(), b.checksum())
	assert_eq(a.to_array(), b.to_array())
	assert_gt(a.player().y_world, 100.0, "the run went somewhere")
	assert_gt(a.spawner.next_id, 3, "and met traffic")
	assert_ne(_scripted(2025, 40 * 60).checksum(), a.checksum(), "another seed, another game")


static func _scripted(seed_value: int, ticks: int) -> World:
	var w := World.new(Config.standard(), seed_value)
	for i in ticks:
		var steer: int = [-1, 0, 1][floori(i / 90.0) % 3]
		w.step(PackedByteArray([PlayerInput.encode(true, false, steer, false)]))
	return w
