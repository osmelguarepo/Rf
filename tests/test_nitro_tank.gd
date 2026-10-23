extends "res://tests/test_case.gd"
## The game's speed rules and the nitro tank (Config.game(), scripts/sim/world.gd step 1 and 6b): both gears reach 400
## km/h, the low gear in 12 s and nitro in 6 s; nitro burns a 6 s tank; 3000 px of road without an accident refill it, and
## an accident loses the road driven towards the refill. The standard profile keeps Phaser's rules and has no tank.

const H := preload("res://tests/sim_helpers.gd")
const Config := preload("res://scripts/sim/config.gd")
const World := preload("res://scripts/sim/world.gd")
const Car := preload("res://scripts/sim/car.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")

var game_cfg := Config.game()


func _byte(nitro: bool, steer: int = 0) -> int:
	return PlayerInput.encode(true, false, steer, nitro)


func test_low_gear_reaches_400_in_12_seconds_and_nitro_in_6() -> void:
	var low := H.quiet_world(game_cfg)
	H.run(low, _byte(false), 12 * 60)
	assert_almost_eq(low.player().speed, 400.0, 1e-6, "low gear after 12 s")
	var low_early := H.quiet_world(game_cfg)
	H.run(low_early, _byte(false), 6 * 60)
	assert_almost_eq(low_early.player().speed, 200.0, 1e-6, "half way after 6 s")
	# The 6 s tank is exactly the climb: a full tank carries a car from a standstill to 400 km/h, and ends empty.
	var tank := H.quiet_world(game_cfg)
	H.run(tank, _byte(true), 6 * 60)
	assert_almost_eq(tank.player().speed, 400.0, 1e-6, "nitro after 6 s")
	assert_almost_eq(tank.player().nitro_tank, 0.0, 1e-9, "the tank is empty at the top")


func test_a_full_tank_burns_in_6_seconds_then_the_low_gear_takes_over() -> void:
	var w := H.quiet_world(game_cfg)
	var car := w.player()
	assert_eq(car.nitro_tank, 1.0, "every car starts with a full tank")
	H.run(w, _byte(true), 5 * 60)
	assert_almost_eq(car.nitro_tank, 1.0 / 6.0, 1e-9, "1 s left")
	assert_eq(car.gear, Car.GEAR_NITRO)
	H.run(w, _byte(true), 60)
	assert_eq(car.nitro_tank, 0.0, "empty")
	H.run(w, _byte(true))
	assert_eq(car.gear, Car.GEAR_LOW, "an empty tank: the low gear, the throttle still held")
	var speed := car.speed
	H.run(w, _byte(true), 60)
	assert_eq(car.nitro_tank, 0.0)
	assert_true(car.speed >= speed, "still accelerating or at the top")


func test_road_without_an_accident_refills_the_tank() -> void:
	var w := H.quiet_world(game_cfg)
	var car := w.player()
	H.run(w, _byte(true), 3 * 60)
	assert_lt(car.nitro_tank, 1.0)
	var guard := 0
	while car.nitro_tank < 1.0 and guard < 3000:
		H.run(w, _byte(false))
		guard += 1
	assert_eq(car.nitro_tank, 1.0, "refilled")
	assert_eq(car.nitro_progress, 0.0)
	# 3000 px, driven at 400 km/h (225 px/s) after a 12 s climb: well under 30 s from the burn.
	assert_lt(guard, 30 * 60)


func test_an_accident_loses_the_road_driven_towards_the_refill() -> void:
	var w := H.quiet_world(game_cfg)
	var car := w.player()
	H.run(w, _byte(true), 3 * 60)
	H.run(w, _byte(false), 4 * 60)
	assert_gt(car.nitro_progress, 0.0, "road driven since the burn")
	var tank := car.nitro_tank
	# Steer into the left roadside until it crashes the car.
	var guard := 0
	while (car.events & World.EV_CRASH) == 0 and guard < 600:
		H.run(w, _byte(false, -1))
		guard += 1
	assert_true((car.events & World.EV_CRASH) != 0, "the car crashed")
	assert_eq(car.nitro_progress, 0.0, "the road towards the refill is lost")
	assert_lt(tank, 1.0)
	assert_gt(tank, 0.0, "there was nitro in the tank")
	assert_eq(car.nitro_tank, 0.0, "the accident empties the tank")
	# The recharge starts over: road driven without an accident after it fills the tank again.
	var guard2 := 0
	while car.nitro_tank < 1.0 and guard2 < 3000:
		H.run(w, _byte(false))
		guard2 += 1
	assert_eq(car.nitro_tank, 1.0, "refilled after 3000 clean px")


func test_the_standard_profile_keeps_the_old_rules_and_has_no_tank() -> void:
	var cfg := Config.standard()
	assert_eq(cfg.nitro_tank_seconds, 0.0)
	var w := H.quiet_world(cfg)
	H.run(w, _byte(true), 20 * 60)
	assert_eq(w.player().gear, Car.GEAR_NITRO, "unlimited")
	assert_eq(w.player().nitro_tank, 1.0)
	assert_eq(Config.standard().low_gear_top, Config.LOW_GEAR_TOP)
