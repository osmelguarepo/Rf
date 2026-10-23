extends "res://tests/test_case.gd"
## Túnel de los Gemelos (scripts/view/tunnel.gd): where the mouths stand (a function of the seed alone), the four
## seconds that start when the camera crosses one, and the cars drawn in one silver while they last.

const Tunnel := preload("res://scripts/view/tunnel.gd")
const Cars := preload("res://scripts/view/cars.gd")
const PlayerColours := preload("res://scripts/view/player_colours.gd")
const Config := preload("res://scripts/sim/config.gd")
const World := preload("res://scripts/sim/world.gd")
const SimHelpers := preload("res://tests/sim_helpers.gd")


func test_mouths_depend_on_the_seed_alone() -> void:
	for k in 5:
		assert_eq(Tunnel.entrance(7, k), Tunnel.entrance(7, k))
		var slot := Tunnel.FIRST + k * Tunnel.SPACING
		assert_between(Tunnel.entrance(7, k), slot, slot + Tunnel.JITTER)
	assert_ne(Tunnel.entrance(7, 0), Tunnel.entrance(8, 0))


func test_visible_finds_the_mouths_in_range() -> void:
	var y0 := Tunnel.entrance(3, 0)
	var y1 := Tunnel.entrance(3, 1)
	assert_eq(Tunnel.visible(3, y0 - 1.0, y0 + 1.0), [0] as Array[int])
	assert_eq(Tunnel.visible(3, y0 - 1.0, y1 + 1.0), [0, 1] as Array[int])
	assert_eq(Tunnel.visible(3, 0.0, Tunnel.FIRST - 1.0), [] as Array[int])


func test_crossing_a_mouth_starts_four_seconds() -> void:
	var w := SimHelpers.quiet_versus(Config.standard(), 3, 2, 3)
	var tunnel := Tunnel.new()
	tunnel.update(w)
	assert_false(tunnel.active(w))
	w.camera_y = Tunnel.entrance(3, 0) + 1.0
	w.stage_ticks = 100
	tunnel.update(w)
	assert_true(tunnel.active(w))
	w.stage_ticks = 100 + Tunnel.TWIN_TICKS - 1
	assert_true(tunnel.active(w))
	w.stage_ticks = 100 + Tunnel.TWIN_TICKS
	assert_false(tunnel.active(w))
	tunnel.update(w)
	assert_false(tunnel.active(w), "the same mouth does not start it again")


func test_a_new_round_starts_afresh() -> void:
	var w := SimHelpers.quiet_versus(Config.standard(), 3, 2, 3)
	var tunnel := Tunnel.new()
	tunnel.update(w)
	w.camera_y = Tunnel.entrance(3, 0) + 1.0
	w.stage_ticks = 500
	tunnel.update(w)
	assert_true(tunnel.active(w))
	w.camera_y = 0.0
	w.stage_ticks = 0
	tunnel.update(w)
	assert_false(tunnel.active(w))
	w.camera_y = Tunnel.entrance(3, 0) + 1.0
	w.stage_ticks = 10
	tunnel.update(w)
	assert_true(tunnel.active(w), "the first mouth works again")


func test_cars_look_alike_in_a_tunnel() -> void:
	var w := SimHelpers.quiet_versus(Config.standard(), 3, 3, 7)
	var colours: Array[int] = [0, 1, 2]
	var normal := Cars.car_draws(w, colours)
	var twin := Cars.car_draws(w, colours, true)
	assert_eq(twin.size(), 3)
	assert_ne(normal[0]["sprite"]["frame"], normal[1]["sprite"]["frame"])
	for draw: Dictionary in twin:
		assert_eq(draw["sprite"]["frame"], twin[0]["sprite"]["frame"])
		assert_eq(draw["fallback"], PlayerColours.TWIN_SHADES[PlayerColours.BODY])
		assert_true(draw["sprite"]["frame"].ends_with("@twin"))
