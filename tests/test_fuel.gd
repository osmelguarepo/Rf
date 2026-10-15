extends "res://tests/test_case.gd"
## Fuel rules (scripts/sim/fuel.gd): the 6 tests of the Phaser tests/fuel.test.ts (commit 0a0841f). Fuel does not
## depend on the screen, so the values are Phaser's; one second is 60 ticks of drain.

const Config := preload("res://scripts/sim/config.gd")
const Fuel := preload("res://scripts/sim/fuel.gd")
const Rng := preload("res://scripts/sim/rng.gd")
const World := preload("res://scripts/sim/world.gd")
const H := preload("res://tests/sim_helpers.gd")

const EPS := 1e-9


func test_drains_one_unit_per_second() -> void:
	assert_almost_eq(Fuel.drain(Config.FUEL_MAX), 100.0 - 1.0 / 60.0, 1e-12, "one tick")
	var amount := Config.FUEL_MAX
	for i in 10 * 60:
		amount = Fuel.drain(amount)
	assert_almost_eq(amount, 90.0, EPS, "ten seconds")


func test_drain_never_goes_below_zero() -> void:
	var amount := 0.5
	for i in 10 * 60:
		amount = Fuel.drain(amount)
	assert_eq(amount, 0.0)
	assert_eq(Fuel.drain(0.0), 0.0)
	assert_true(Fuel.is_empty(amount))


func test_a_pickup_refills_10_capped_at_the_tank() -> void:
	assert_eq(Fuel.collect(50.0), 60.0)
	assert_eq(Fuel.collect(95.0), 100.0)
	assert_eq(Fuel.collect(100.0), 100.0)


## Four fuel cars in a row: 1000 each time, no chain bonus.
func test_a_fuel_car_pays_a_flat_1000_every_time() -> void:
	var w := H.quiet_world(Config.standard())
	w.player().fuel = 50.0
	for i in 4:
		H.on_car(w, Config.KIND_FUEL_CAR)
		H.run(w, H.NONE)
		assert_true((w.events & World.EV_PICKUP) != 0, "pickup %d" % (i + 1))
		assert_eq(w.player().score, 1000 * (i + 1), "score after pickup %d" % (i + 1))
	assert_eq(Config.FUEL_CAR_POINTS, 1000)


func test_a_roadside_crash_costs_5_or_6_units() -> void:
	var rng := Rng.new(7)
	var seen := {}
	for i in 50:
		var cost := 80.0 - Fuel.apply_crash(80.0, rng)
		assert_true(cost == 5.0 or cost == 6.0, "draw %d cost %s" % [i, cost])
		seen[cost] = true
	assert_eq(seen.size(), 2, "both costs occur in 50 draws")


func test_a_crash_never_leaves_the_tank_below_zero() -> void:
	assert_eq(Fuel.apply_crash(2.0, Rng.new(1)), 0.0)
