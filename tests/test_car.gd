extends "res://tests/test_case.gd"
## Car rules (scripts/sim/car.gd): the 20 tests of the Phaser tests/car.test.ts (commit 0a0841f), recomputed for
## the six-lane profile, plus the plan's steering and skid tests. tests/PARITY.md maps each Phaser test here.
##
## Phaser called stepSpeed() and stepLateral() with dt = 1 s or 0.1 s; the port has one fixed step of 1/60 s, so
## those expectations are per tick, or over 60 ticks for one second.

const Config := preload("res://scripts/sim/config.gd")
const Car := preload("res://scripts/sim/car.gd")
const Traffic := preload("res://scripts/sim/traffic.gd")
const World := preload("res://scripts/sim/world.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")
const H := preload("res://tests/sim_helpers.gd")

const DT := Config.DT
const EPS := 1e-9
## Left edge of the single player's car in the six-lane profile: lane 2, 188 + 2 x 44 + (44 - 14) / 2.
const START_X := 291.0

var std := Config.standard()
var phs := Config.phaser()


# --- gear ------------------------------------------------------------------------------------------------------------


func test_gear_is_high_only_while_held() -> void:
	var w := H.quiet_world(std)
	H.run(w, H.ACCEL_HIGH)
	assert_eq(w.player().gear, Car.GEAR_NITRO, "A (X) held")
	H.run(w, H.ACCEL)
	assert_eq(w.player().gear, Car.GEAR_LOW, "released")
	H.run(w, PlayerInput.NITRO | PlayerInput.STEER_NONE)
	assert_eq(w.player().gear, Car.GEAR_NITRO, "held without throttle")
	H.run(w, H.NONE)
	assert_eq(w.player().gear, Car.GEAR_LOW, "no input")


# --- speed -----------------------------------------------------------------------------------------------------------


func test_low_gear_tops_out_at_198() -> void:
	assert_eq(_run_speed(0.0, Car.GEAR_LOW, true, false, 20 * 60), Config.LOW_GEAR_TOP)
	assert_eq(Config.LOW_GEAR_TOP, 198.0)


func test_nitro_reaches_400() -> void:
	assert_eq(_run_speed(0.0, Car.GEAR_NITRO, true, false, 40 * 60), Config.NITRO_TOP)
	assert_eq(Config.NITRO_TOP, 400.0)


## 15 km/h/s below 160 km/h, then 45 km/h/s: per tick 0.25 and 0.75; over one second 15 and 45.
func test_nitro_is_slow_below_160_then_faster() -> void:
	assert_almost_eq(Car.step_speed(0.0, Car.GEAR_NITRO, true, false), 0.25, 1e-12, "one tick from 0")
	assert_almost_eq(Car.step_speed(200.0, Car.GEAR_NITRO, true, false), 200.75, 1e-12, "one tick from 200")
	assert_almost_eq(_run_speed(0.0, Car.GEAR_NITRO, true, false, 60), 15.0, EPS, "one second from 0")
	assert_almost_eq(_run_speed(200.0, Car.GEAR_NITRO, true, false, 60), 245.0, EPS, "one second from 200")


func test_coasting_loses_drag() -> void:
	assert_almost_eq(Car.step_speed(100.0, Car.GEAR_LOW, false, false), 100.0 - 25.0 / 60.0, 1e-12)
	assert_almost_eq(_run_speed(100.0, Car.GEAR_LOW, false, false, 60), 75.0, EPS, "one second")


func test_brake_beats_throttle_and_stops_at_zero() -> void:
	assert_almost_eq(Car.step_speed(10.0, Car.GEAR_LOW, true, true), 8.0, 1e-12, "120 km/h/s, throttle ignored")
	assert_eq(_run_speed(10.0, Car.GEAR_LOW, true, true, 60), 0.0, "one second: stopped, not negative")


func test_overspeed_falls_back_at_25_per_second() -> void:
	assert_almost_eq(Car.step_speed(350.0, Car.GEAR_LOW, false, false), 350.0 - 25.0 / 60.0, 1e-12, "not instantly")
	assert_almost_eq(_run_speed(350.0, Car.GEAR_LOW, false, false, 60), 325.0, EPS, "one second")


func test_throttle_above_the_gear_top_does_not_accelerate() -> void:
	var speed := Car.step_speed(Config.LOW_GEAR_TOP + 5.0, Car.GEAR_LOW, true, false)
	assert_lt(speed, Config.LOW_GEAR_TOP + 5.0)
	assert_almost_eq(speed, 203.0 - 25.0 / 60.0, 1e-12)


# --- steering --------------------------------------------------------------------------------------------------------


## Phaser: 0 while stopped, 170 - 0.1 x 30 = 167 px/s from 30 km/h. Six lanes: x K = 93.9375 px/s.
func test_steer_rate_is_zero_stopped_and_full_from_30() -> void:
	assert_eq(Car.steer_rate(std, 0.0), 0.0)
	assert_almost_eq(Car.steer_rate(std, 30.0), 93.9375, EPS)
	assert_almost_eq(Car.steer_rate(std, 15.0), (95.625 - 0.05625 * 15.0) / 2.0, EPS, "half the rate at 15 km/h")
	assert_almost_eq(Car.steer_rate(phs, 30.0), 167.0, EPS)


## Phaser: about 150 px/s at 198 km/h and 130 px/s at 400 km/h. Six lanes: 84.4875 and 73.125 px/s.
func test_steer_rate_at_198_and_400() -> void:
	assert_almost_eq(Car.steer_rate(std, 198.0), 84.4875, EPS)
	assert_almost_eq(Car.steer_rate(std, 400.0), 73.125, EPS)
	assert_almost_eq(Car.steer_rate(phs, 198.0), 150.2, EPS)
	assert_almost_eq(Car.steer_rate(phs, 400.0), 130.0, EPS)


## Plan §4: every px/s magnitude is Phaser's x K. Checked at 0.5 km/h steps from 0 to 420.
func test_steer_rate_is_phaser_times_k() -> void:
	var worst := 0.0
	for i in 841:
		var speed := float(i) * 0.5
		var phaser_rate := Car.steer_rate(phs, speed)
		worst = maxf(worst, absf(Car.steer_rate(std, speed) - phaser_rate * Config.K))
	assert_lt(worst, 1e-12, "largest difference from Phaser x K, px/s")
	assert_eq(std.steer_base, 170.0 * Config.K)
	assert_eq(std.steer_per_kmh, 0.1 * Config.K)


func test_steering_moves_at_the_speed_rate() -> void:
	var car := H.car(std, START_X, 198.0)
	var hit := Car.step_lateral(std, car, 1)
	assert_almost_eq(car.x, START_X + Car.steer_rate(std, 198.0) * DT, 1e-12)
	assert_almost_eq(car.x, 292.408125, EPS, "84.4875 px/s for one tick")
	assert_false(hit)


func test_steering_into_the_barrier_is_a_roadside_hit() -> void:
	var left := H.car(std, std.road_left, 100.0)
	assert_true(Car.step_lateral(std, left, -1), "left barrier")
	assert_eq(left.x, 188.0, "held at the edge")
	var right := H.car(std, std.road_right - std.player_w, 100.0)
	assert_true(Car.step_lateral(std, right, 1), "right barrier")
	assert_eq(right.x, 438.0, "held at the edge")


func test_a_slide_into_the_roadside_is_a_hit() -> void:
	var car := H.car(std, std.road_left, 100.0)
	Car.start_skid(std, car, -1)
	assert_true(Car.step_lateral(std, car, 0))
	assert_eq(car.slide_vx, 0.0, "the slide stops at the edge")
	assert_eq(car.x, 188.0)


func test_skidding_ignores_steering() -> void:
	var car := H.car(std, START_X, 150.0)
	Car.start_skid(std, car, 1)
	Car.step_lateral(std, car, -1)
	assert_almost_eq(car.x, START_X + 50.625 * DT, 1e-12, "the slide alone moves the car: 90 x K px/s")
	assert_eq(car.slide_vx, 50.625, "steering against the slide does not slow it")


## Plan §6: 90 px/s at 360 px/s² is 15 steps; x K (50.625 at 202.5) keeps 15.
func test_skid_recovers_in_15_steps() -> void:
	for cfg: Config in [std, phs]:
		var car := H.car(cfg, Traffic.lane_x(cfg, cfg.start_lane, cfg.player_w), 0.0)
		Car.start_skid(cfg, car, 1)
		var steps := 0
		while car.slide_vx != 0.0 and steps < 600:
			Car.step_lateral(cfg, car, 1)
			steps += 1
		assert_eq(steps, 15, "profile %d" % cfg.profile)
		assert_eq(car.slide_vx, 0.0)


func test_steering_against_or_not_at_all_keeps_the_slide() -> void:
	var car := H.car(std, START_X, 100.0)
	Car.start_skid(std, car, 1)
	Car.step_lateral(std, car, -1)
	assert_eq(car.slide_vx, 50.625, "steering against")
	Car.step_lateral(std, car, 0)
	assert_eq(car.slide_vx, 50.625, "not steering")


## Plan §6: time for an uncorrected skid to reach the roadside, per lane. 0.84375 px per tick (50.625 px/s).
## Six lanes: from the start lane (2), 123 ticks (2.05 s) to the left and 175 (2.92 s) to the right, so Phaser's
## "within 2 seconds from the centre lane" (72 ticks, 1.2 s) only holds for lanes 0-1 to the left and 4-5 to the
## right.
func test_skid_time_to_the_edge_per_lane() -> void:
	assert_eq(_ticks_to_edge_per_lane(std, -1), [18, 70, 123, 175, 227, 279], "six lanes, sliding left")
	assert_eq(_ticks_to_edge_per_lane(std, 1), [279, 227, 175, 123, 70, 18], "six lanes, sliding right")
	assert_eq(_ticks_to_edge_per_lane(phs, -1), [19, 72, 125], "Phaser, sliding left")
	assert_eq(_ticks_to_edge_per_lane(phs, 1), [125, 72, 19], "Phaser, sliding right")
	assert_lt(_ticks_to_edge(phs, phs.start_lane, -1), 2 * 60, "Phaser: within 2 s from the centre lane")


# --- crash and bump --------------------------------------------------------------------------------------------------


## Phaser set 1.5 s and counted it down in float seconds; 1.5 - 90 x (1/60) leaves 3.3e-16, so it lasted 91 ticks.
func test_a_crash_drops_speed_to_30_percent_and_starts_invulnerability() -> void:
	var car := H.car(std, START_X, 200.0)
	car.slide_vx = 50.0
	Car.apply_crash(car)
	assert_almost_eq(car.speed, 60.0, EPS)
	assert_eq(car.invulnerable, Config.INVULNERABLE_TICKS)
	assert_eq(Config.INVULNERABLE_TICKS, 91)
	assert_eq(car.slide_vx, 0.0)


func test_a_bump_keeps_speed_and_skids_away() -> void:
	var car := H.car(std, START_X, 150.0)
	Car.apply_bump(std, car, -1)
	assert_eq(car.speed, 150.0)
	assert_lt(car.slide_vx, 0.0)
	assert_eq(car.slide_vx, -50.625)
	assert_eq(car.invulnerable, Config.INVULNERABLE_TICKS)


func test_the_car_keeps_the_player_hitbox() -> void:
	var car := World.new(std, 1).player()
	assert_eq([car.w, car.h], [14.0, 24.0], "six lanes")
	var phaser_car := World.new(phs, 1).player()
	assert_eq([phaser_car.w, phaser_car.h], [26.0, 44.0], "Phaser")


# --- helpers ---------------------------------------------------------------------------------------------------------


static func _run_speed(speed: float, gear: int, accel: bool, brake: bool, ticks: int) -> float:
	var s := speed
	for i in ticks:
		s = Car.step_speed(s, gear, accel, brake)
	return s


## Ticks until an uncorrected skid from the centre of a lane reports the roadside.
static func _ticks_to_edge(cfg: Config, lane: int, direction: int) -> int:
	var car := H.car(cfg, Traffic.lane_x(cfg, lane, cfg.player_w), 100.0)
	Car.start_skid(cfg, car, direction)
	for tick in 10000:
		if Car.step_lateral(cfg, car, 0):
			return tick + 1
	return -1


static func _ticks_to_edge_per_lane(cfg: Config, direction: int) -> Array:
	var out: Array = []
	for lane in cfg.lane_count:
		out.append(_ticks_to_edge(cfg, lane, direction))
	return out
