extends "res://tests/test_case.gd"
## Geometry and the conversion from Phaser (docs/GODOT_PLAN.md §3-4): the six-lane road, hitboxes, the anchor and
## camera, every px value = Phaser's x K, and the phaser profile used by the golden tests.

const Config := preload("res://scripts/sim/config.gd")
const Traffic := preload("res://scripts/sim/traffic.gd")
const World := preload("res://scripts/sim/world.gd")
const H := preload("res://tests/sim_helpers.gd")

var std := Config.standard()
var phs := Config.phaser()


## 640x360; 6 lanes of 44 px = 264 px from x = 188 to 452; the single player starts in lane 2, centre x = 298.
func test_six_lane_road() -> void:
	assert_eq(Config.K, 0.5625, "360 / 640")
	assert_eq([std.view_width, std.view_height], [640.0, 360.0])
	assert_eq([std.lane_count, std.lane_width], [6, 44.0])
	assert_eq([std.road_left, std.road_right], [188.0, 452.0])
	assert_eq(std.road_right - std.road_left, 264.0)
	assert_eq(std.start_lane, 2)
	assert_eq(Traffic.lane_x(std, 2, std.player_w) + std.player_w / 2.0, 298.0, "start lane centre")
	var centres: Array = []
	for lane in std.lane_count:
		centres.append(Traffic.lane_x(std, lane, 10.0) + 5.0)
	assert_eq(centres, [210.0, 254.0, 298.0, 342.0, 386.0, 430.0])


## Sprites at 2x, hitboxes 1 px narrower on each side: cars 14x24, small car 10x20, truck 18x40, oil 18x12.
func test_hitboxes() -> void:
	assert_eq([std.player_w, std.player_h], [14.0, 24.0], "player")
	var sizes: Array = []
	for kind in Config.KIND_COUNT:
		sizes.append([std.kind_w[kind], std.kind_h[kind]])
	assert_eq(sizes, [[10.0, 20.0], [14.0, 24.0], [14.0, 24.0], [18.0, 40.0], [14.0, 24.0], [18.0, 12.0]],
		"yellow (small car), red, blue, truck, fuel car, oil")


## Every px or px/s value is Phaser's x K; car and oil gaps also x 3/6 (six lanes share three lanes' traffic).
func test_px_values_are_phaser_times_k() -> void:
	var got := [
		std.px_per_kmh, std.steer_base, std.steer_per_kmh, std.skid_speed, std.correction_accel,
		std.lane_change_speed, std.spawn_above, std.spawn_busy_y, std.off_bottom, std.off_top, std.blue_reach,
		std.goal_scale, std.fuel_gap, std.fuel_gap_jitter,
	]
	var phaser := [
		phs.px_per_kmh, phs.steer_base, phs.steer_per_kmh, phs.skid_speed, phs.correction_accel,
		phs.lane_change_speed, phs.spawn_above, phs.spawn_busy_y, phs.off_bottom, phs.off_top, phs.blue_reach,
		phs.goal_scale, phs.fuel_gap, phs.fuel_gap_jitter,
	]
	var scaled: Array = []
	for value: float in phaser:
		scaled.append(value * Config.K)
	assert_eq(got, scaled)
	assert_eq(got, [
		0.5625, 95.625, 0.05625, 50.625, 202.5, 67.5, 2.25, 56.25, 11.25, 67.5, 112.5, 0.5625, 4500.0, 1125.0
	])
	assert_eq([std.car_gap, std.car_gap_jitter, std.car_gap_min], [98.4375, 0.0, 56.25], "car gap x K x 3/6")
	assert_eq([std.oil_gap, std.oil_gap_jitter], [1125.0, 281.25], "oil gap x K x 3/6")


## Single player: the car's top edge is at y = 292 (520 x K, rounded down) and stays there; the camera follows it
## and never moves back.
func test_anchor_and_camera_follow_the_player() -> void:
	assert_eq(std.anchor_single, 292.0)
	var w := World.new(std, 77)
	var p := w.player()
	var off_anchor := 0
	var went_back := 0
	var last_camera := w.camera_y
	for tick in 1200:
		var byte := H.ACCEL_HIGH if tick < 900 else H.BRAKE
		H.run(w, byte)
		if w.phase != World.RUNNING:
			break
		if w.screen_y(p.y_world) != w.anchor or w.camera_y != p.y_world:
			off_anchor += 1
		if w.camera_y < last_camera:
			went_back += 1
		last_camera = w.camera_y
	assert_eq(off_anchor, 0, "ticks where the player was off the anchor line")
	assert_eq(went_back, 0, "ticks where the camera moved back")
	assert_gt(w.camera_y, 100.0)


## The phaser profile is Phaser's own geometry and numbers, for the golden tests.
func test_phaser_profile_is_phasers_numbers() -> void:
	assert_eq(phs.k, 1.0)
	assert_eq([phs.view_width, phs.view_height, phs.lane_count, phs.lane_width], [360.0, 640.0, 3, 80.0])
	assert_eq([phs.road_left, phs.road_right, phs.anchor_single, phs.start_lane], [60.0, 300.0, 520.0, 1])
	assert_eq([phs.player_w, phs.player_h], [26.0, 44.0])
	assert_eq(phs.kind_w, [24.0, 24.0, 24.0, 30.0, 24.0, 40.0] as Array[float])
	assert_eq(phs.kind_h, [40.0, 40.0, 40.0, 60.0, 40.0, 24.0] as Array[float])
	assert_eq([phs.car_gap, phs.car_gap_min, phs.oil_gap, phs.oil_gap_jitter], [350.0, 200.0, 4000.0, 1000.0])
	assert_eq([phs.fuel_gap, phs.fuel_gap_jitter, phs.adjacent_lanes], [8000.0, 2000.0, 0])
	assert_eq(std.adjacent_lanes, 1)


## Profiles are values: a clone is equal and independent, and for_profile() picks the right one.
func test_profiles_clone_and_select() -> void:
	var copy := std.clone()
	assert_eq(_fields(copy), _fields(std))
	copy.kind_w[0] = 99.0
	assert_eq(std.kind_w[0], 10.0, "the clone does not share its arrays")
	assert_eq(Config.for_profile(Config.PROFILE_PHASER).profile, Config.PROFILE_PHASER)
	assert_eq(Config.for_profile(Config.PROFILE_STANDARD).lane_count, 6)


static func _fields(cfg: Config) -> Dictionary:
	var out := {}
	for property: Dictionary in cfg.get_property_list():
		if (int(property["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE) != 0:
			out[property["name"]] = cfg.get(property["name"])
	return out
