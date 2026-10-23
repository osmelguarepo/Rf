extends "res://tests/test_case.gd"
## Nitro flames (scripts/view/cars.gd, nitro_flames()): a car with nitro on and moving shows two flames below its
## bottom edge; low gear, a stopped car and a dead car show none. Only the look: nothing here steps the simulation.

const Cars := preload("res://scripts/view/cars.gd")
const Car := preload("res://scripts/sim/car.gd")
const Config := preload("res://scripts/sim/config.gd")
const SimHelpers := preload("res://tests/sim_helpers.gd")


func test_nitro_shows_two_flames_below_the_car() -> void:
	var w := SimHelpers.quiet_world(Config.standard())
	var car: Car = w.players[0]
	car.gear = Car.GEAR_NITRO
	car.speed = 200.0
	var flames := Cars.nitro_flames(w)
	assert_eq(flames.size(), 4, "an outer and an inner rect for each of two pipes")
	var bottom := Cars.hitbox_pos(w, car.x, car.y_world).y + roundi(car.h)
	for f: Dictionary in flames:
		assert_eq(f["rect"].position.y, bottom, "the flame starts at the car's bottom edge")
		assert_true(f["rect"].size.y >= 2)


func test_no_flames_in_low_gear_stopped_or_dead() -> void:
	var w := SimHelpers.quiet_world(Config.standard())
	var car: Car = w.players[0]
	car.speed = 200.0
	assert_eq(Cars.nitro_flames(w).size(), 0, "low gear")
	car.gear = Car.GEAR_NITRO
	car.speed = 0.0
	assert_eq(Cars.nitro_flames(w).size(), 0, "stopped")
	car.speed = 200.0
	car.alive = 0
	assert_eq(Cars.nitro_flames(w).size(), 0, "not in the round")


func test_the_flames_flicker() -> void:
	var w := SimHelpers.quiet_world(Config.standard())
	var car: Car = w.players[0]
	car.gear = Car.GEAR_NITRO
	car.speed = 200.0
	var lengths := {}
	for t in 40:
		w.stage_ticks = t
		lengths[Cars.nitro_flames(w)[0]["rect"].size.y] = true
	assert_true(lengths.size() > 1, "the length changes with the stage clock")
