extends "res://tests/test_case.gd"
## The developer dashboard's values (scripts/app/tuning.gd): shipped values change nothing, a changed rule reaches the
## cars, time scale reaches the clock, presets keep values, and F1 only opens the panel with --admin.

const Tuning := preload("res://scripts/app/tuning.gd")
const App := preload("res://scripts/app/app.gd")
const Car := preload("res://scripts/sim/car.gd")
const Config := preload("res://scripts/sim/config.gd")


func test_shipped_values_change_nothing() -> void:
	var tuning := Tuning.new()
	var cfg := Config.game()
	var before := cfg.low_gear_top
	tuning.apply(cfg)
	assert_eq(cfg.low_gear_top, before)
	assert_true(tuning.is_default())
	for field: Dictionary in Tuning.FIELDS:
		assert_eq(tuning.value(field["key"]), Tuning.default_of(field["key"]), field["key"])
	assert_almost_eq(Car.step_speed(100.0, Car.GEAR_LOW, true, false, cfg), 100.0 + 400.0 / 12.0 / 60.0, 1e-9)


func test_a_changed_rule_reaches_the_car_and_is_clamped() -> void:
	var tuning := Tuning.new()
	var cfg := Config.standard()
	tuning.set_value("low_gear_top", 120.0)
	tuning.set_value("brake_decel", 1.0e9)
	tuning.apply(cfg)
	assert_eq(cfg.low_gear_top, 120.0)
	assert_eq(Car.gear_top(Car.GEAR_LOW, cfg), 120.0)
	assert_eq(cfg.brake_decel, 600.0, "kept within the slider's range")
	assert_eq(Car.step_speed(119.99, Car.GEAR_LOW, true, false, cfg), 120.0, "the new top")
	tuning.set_value("low_gear_top", Config.game().low_gear_top)
	assert_false(tuning.values.has("low_gear_top"), "the shipped value is forgotten")
	tuning.set_value("no_such_field", 3.0)
	assert_false(tuning.values.has("no_such_field"))


func test_time_scale_gives_the_clock_more_steps() -> void:
	var app := App.new()
	app.tuning.set_value(Tuning.TIME_SCALE, 2.0)
	assert_eq(app.clock.advance(1.0 / 60.0 * app.tuning.value(Tuning.TIME_SCALE)), 2)
	app.free()


func test_presets_keep_values() -> void:
	var tuning := Tuning.new()
	tuning.set_value("nitro_top", 500.0)
	tuning.set_value(Tuning.TIME_SCALE, 1.5)
	assert_true(tuning.save_preset(5))
	tuning.reset()
	assert_true(tuning.is_default())
	assert_true(tuning.load_preset(5))
	assert_eq(tuning.value("nitro_top"), 500.0)
	assert_eq(tuning.value(Tuning.TIME_SCALE), 1.5)
	assert_false(tuning.save_preset(0))
	tuning.reset()
	tuning.save_preset(5)


func test_f1_is_the_admin_key() -> void:
	var f1 := InputEventKey.new()
	f1.physical_keycode = KEY_F1
	f1.pressed = true
	assert_true(App.is_admin_key(f1))
	f1.echo = true
	assert_false(App.is_admin_key(f1), "not a repeat")
	var app := App.new()
	assert_false(app.admin_enabled, "off without --admin")
	app.free()
