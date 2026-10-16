extends "res://tests/test_case.gd"
## The view (scripts/view/, docs/GODOT_PLAN.md §4-5): the atlas and the code-drawn sprites, where sprites land on
## their hitboxes, the road's tiles, the HUD layout, and the rules for blinking, the rainbow and messages. What it
## looks like is checked by eye on the screenshots (tools/screenshots.gd); pixel scaling by tools/scalecheck.gd.

const ViewConfig := preload("res://scripts/view/view_config.gd")
const Atlas := preload("res://scripts/view/atlas.gd")
const PixelArt := preload("res://scripts/view/pixel_art.gd")
const Draw := preload("res://scripts/view/draw.gd")
const Road := preload("res://scripts/view/road.gd")
const Cars := preload("res://scripts/view/cars.gd")
const Hud := preload("res://scripts/view/hud.gd")
const TitleView := preload("res://scripts/view/title_view.gd")
const Game := preload("res://scripts/app/game.gd")
const Config := preload("res://scripts/sim/config.gd")
const World := preload("res://scripts/sim/world.gd")
const Car := preload("res://scripts/sim/car.gd")
const Traffic := preload("res://scripts/sim/traffic.gd")

var atlas: Atlas
var cfg: Config


func before_all() -> void:
	atlas = Atlas.new()
	atlas.load_all()
	cfg = Config.standard()


func test_the_atlas_has_every_frame_as_an_atlas_texture() -> void:
	var map: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(ViewConfig.ATLAS_JSON))
	assert_true(Atlas.new().load_all(), "atlas, frames and font load")
	assert_eq(atlas.frames.size(), map.size() + PixelArt.GRIDS.size())
	var wrong: Array = []
	for name: String in map:
		var tex := atlas.frame(name) as AtlasTexture
		var rect: Dictionary = map[name]
		var expected := Rect2(rect["x"], rect["y"], rect["w"], rect["h"])
		if tex == null or tex.atlas != atlas.texture or tex.region != expected or not tex.filter_clip:
			wrong.append(name)
	assert_eq(wrong, [], "frames whose AtlasTexture does not match sprites.json")
	assert_eq(atlas.frame_size("car_red"), Vector2i(9, 13))
	assert_eq(atlas.frame_size("car_small_yellow"), Vector2i(7, 11))
	assert_eq(atlas.frame_size("car_red_cw45"), Vector2i(14, 14))
	assert_eq(atlas.frame_size("no_such_frame"), Vector2i.ZERO)


func test_the_font_is_press_start_2p_without_smoothing() -> void:
	var font := atlas.font as FontFile
	assert_not_null(font)
	assert_true(font.resource_path.ends_with("press-start-2p-latin-400-normal.woff2"))
	assert_eq(font.antialiasing, TextServer.FONT_ANTIALIASING_NONE)
	assert_eq(font.hinting, TextServer.HINTING_NONE)
	assert_eq(font.subpixel_positioning, TextServer.SUBPIXEL_POSITIONING_DISABLED)
	for size: int in ViewConfig.TEXT_SIZES:
		assert_eq(font.get_ascent(size), float(size), "ascent at %d" % size)
		assert_eq(Draw.text_width(font, "SCORE", size), 5 * size, "monospaced at %d" % size)


## The truck and the oil puddle are Phaser's pixel grids: rectangular, every character in the palette.
func test_the_code_drawn_sprites_are_phasers_grids() -> void:
	assert_eq(PixelArt.GRIDS.keys(), ["truck", "oil_puddle"])
	var truck := PixelArt.to_image(PixelArt.TRUCK)
	var oil := PixelArt.to_image(PixelArt.OIL_PUDDLE)
	assert_eq(truck.get_size(), Vector2i(11, 21))
	assert_eq(oil.get_size(), Vector2i(10, 6))
	assert_eq(truck.get_pixel(2, 0), PixelArt.PALETTE["G"], "dark green cab corner")
	assert_eq(truck.get_pixel(0, 0).a, 0.0, "'.' is transparent")
	assert_eq(oil.get_pixel(3, 1), PixelArt.PALETTE["w"], "the shine")
	assert_eq(atlas.frame_size("truck"), Vector2i(11, 21))
	assert_eq(atlas.frame_size("oil_puddle"), Vector2i(10, 6))


## Plan §4: sprites at 2x are 16x24, 12x20, 20x40 and 20x12, each 2 px wider than its hitbox and as tall.
func test_every_sprite_is_its_hitbox_plus_one_pixel_a_side() -> void:
	assert_eq(ViewConfig.TRAFFIC.size(), Config.KIND_COUNT)
	var wrong: Array = []
	var specs: Array = ViewConfig.TRAFFIC.duplicate()
	specs.append(ViewConfig.PLAYER)
	for i in specs.size():
		var spec: Dictionary = specs[i]
		var hitbox := Vector2i(roundi(cfg.player_w), roundi(cfg.player_h))
		if i < Config.KIND_COUNT:
			hitbox = Vector2i(roundi(cfg.kind_w[i]), roundi(cfg.kind_h[i]))
		var body := (atlas.frame_size(spec["frame"]) - Vector2i(spec["shadow"], spec["shadow"])) * ViewConfig.SPRITE_SCALE
		if body != hitbox + Vector2i(2, 0):
			wrong.append("%s: body %s, hitbox %s" % [spec["frame"], body, hitbox])
	assert_eq(wrong, [], "sprites that are not their hitbox plus 1 px a side")


func test_sprites_are_centred_on_their_hitbox() -> void:
	var at := Vector2i(291, 292)
	assert_eq(Draw.place_on_hitbox(Vector2i(9, 13), 1, 2, at, Vector2i(14, 24)), Vector2i(290, 292), "car")
	assert_eq(Draw.place_on_hitbox(Vector2i(7, 11), 1, 2, at, Vector2i(10, 20)), Vector2i(290, 292), "small car")
	assert_eq(Draw.place_on_hitbox(Vector2i(11, 21), 1, 2, at, Vector2i(18, 40)), Vector2i(290, 292), "truck")
	assert_eq(Draw.place_on_hitbox(Vector2i(10, 6), 0, 2, at, Vector2i(18, 12)), Vector2i(290, 292), "oil")
	assert_eq(Draw.place_on_hitbox(Vector2i(14, 14), 1, 2, at, Vector2i(14, 24)), Vector2i(285, 291), "skidding car")


func test_the_player_turns_towards_the_slide() -> void:
	var car := Car.new()
	assert_eq(Cars.player_sprite(car), ViewConfig.PLAYER)
	car.slide_vx = -cfg.skid_speed
	assert_eq(Cars.player_sprite(car)["frame"], "car_red_ccw45")
	car.slide_vx = cfg.skid_speed
	assert_eq(Cars.player_sprite(car)["frame"], "car_red_cw45")


## Phaser: hidden while invulnerable on every other tenth of a second of the stage clock.
func test_the_player_blinks_at_10_hz_while_invulnerable() -> void:
	var car := Car.new()
	var seen: Array = []
	for tick in 24:
		seen.append(Cars.player_visible(car, tick))
	assert_false(seen.has(false), "always visible when not invulnerable")
	car.invulnerable = 30
	seen.clear()
	for tick in 24:
		seen.append(Cars.player_visible(car, tick))
	var expected: Array = []
	for tick in 24:
		expected.append(floori(tick / 6.0) % 2 == 1)
	assert_eq(seen, expected)


## Phaser's hueToColour: each channel rounded to a byte; a full trip round the hue circle every 90 ticks (1.5 s).
func test_the_fuel_car_cycles_through_the_rainbow() -> void:
	var expected := {
		0: Color8(255, 0, 0), 30: Color8(255, 128, 0), 60: Color8(255, 255, 0), 120: Color8(0, 255, 0),
		180: Color8(0, 255, 255), 240: Color8(0, 0, 255), 300: Color8(255, 0, 255), 330: Color8(255, 0, 128),
		360: Color8(255, 0, 0), -60: Color8(255, 0, 255),
	}
	for hue: int in expected:
		assert_eq(Cars.hue_colour(hue), expected[hue], "hue %d" % hue)
	assert_eq(Cars.rainbow(0), Cars.rainbow(90), "one cycle every 1.5 s")
	assert_eq(Cars.rainbow(15), Color8(255, 255, 0), "60 degrees after a quarter second")


## The view rounds the camera before the world y, so the car on the camera is always on the anchor line and an
## object standing on the road keeps its distance to the road tiles.
func test_the_camera_car_sits_on_the_anchor_and_the_road_moves_with_objects() -> void:
	var w := World.new(cfg, 1)
	var p := w.player()
	for y: float in [0.0, 10.4, 10.5, 10.6, 1234.49, 1234.5]:
		p.y_world = y
		w.camera_y = y
		assert_eq(Cars.screen_top(w, p.y_world), 292, "camera at %s" % y)
	var oil_y := 500.3
	var first := -1
	for camera: float in [400.0, 400.3, 400.5, 401.7, 455.2]:
		w.camera_y = camera
		var gap := Cars.screen_top(w, oil_y) - Cars.camera_px(w)
		if first < 0:
			first = gap
		assert_eq(gap, first, "an oil patch and the road stay together at camera %s" % camera)
	w.camera_y = 400.0
	assert_almost_eq(float(Cars.screen_top(w, oil_y)), w.screen_y(oil_y), 1.0, "within 1 px of the float position")


func test_the_edge_tiles_put_their_white_lines_on_the_barriers() -> void:
	var left_line := Road.edge_left_x(cfg) + ViewConfig.EDGE_LINE_LEFT * ViewConfig.TILE_SCALE
	var right_line := Road.edge_right_x(cfg) + ViewConfig.EDGE_LINE_RIGHT * ViewConfig.TILE_SCALE
	assert_eq(left_line + ViewConfig.BARRIER_W, int(cfg.road_left), "left barrier ends where the road starts")
	assert_eq(right_line, int(cfg.road_right), "right barrier starts where the road ends")
	assert_eq([left_line, right_line], [186, 452])


func test_a_row_of_tiles_covers_the_screen_without_gaps_or_overlaps() -> void:
	var xs: Array = []
	var frames := {}
	for column: Dictionary in Road.columns(cfg):
		xs.append(column["x"])
		frames[column["frame"]] = true
	xs.sort()
	assert_lt(xs[0], 1, "starts at or left of the screen's edge")
	assert_gt(xs[-1] + ViewConfig.TILE, ViewConfig.VIEW_W - 1, "reaches the right edge")
	var gaps: Array = []
	for i in range(1, xs.size()):
		if xs[i] - xs[i - 1] != ViewConfig.TILE:
			gaps.append("%d -> %d" % [xs[i - 1], xs[i]])
	assert_eq(gaps, [], "neighbouring tiles not exactly one tile apart")
	for name: String in [ViewConfig.ROAD_ASPHALT, ViewConfig.ROAD_EDGE_LEFT, ViewConfig.ROAD_EDGE_RIGHT,
			ViewConfig.ROAD_VERGE_LEFT, ViewConfig.ROAD_VERGE_RIGHT, ""]:
		assert_true(frames.has(name), "uses %s" % name)
	for row in 14:
		assert_true(atlas.has_frame(Road.grass_frame(row, row % 2 == 0)))


func test_lane_dashes_are_centred_between_lanes() -> void:
	for lane in range(1, cfg.lane_count):
		var boundary := cfg.road_left + cfg.lane_width * lane
		var x := int(boundary) - (ViewConfig.DASH_W >> 1)
		assert_eq(float(x) + ViewConfig.DASH_W / 2.0, boundary, "lane %d" % lane)


## The HUD and the title's boxes stay off the road and its verges, which run from x 168 to 472.
func test_panels_leave_the_road_and_verges_clear() -> void:
	var verge_left := Road.edge_left_x(cfg) - ViewConfig.TILE
	var verge_right_end := Road.edge_right_x(cfg) + ViewConfig.TILE * 2
	assert_eq([verge_left, verge_right_end], [168, 472])
	for r: Rect2i in [ViewConfig.PANEL_LEFT, ViewConfig.CONTROLS_LEFT]:
		assert_lt(r.end.x, verge_left + 1, "left box %s" % r)
		assert_gt(r.position.x, -1)
	for r: Rect2i in [ViewConfig.PANEL_RIGHT, ViewConfig.CONTROLS_RIGHT]:
		assert_gt(r.position.x, verge_right_end - 1, "right box %s" % r)
		assert_lt(r.end.x, ViewConfig.VIEW_W + 1)
	for r: Rect2i in [ViewConfig.PANEL_LEFT, ViewConfig.PANEL_RIGHT, ViewConfig.CONTROLS_LEFT, ViewConfig.CONTROLS_RIGHT]:
		assert_true(Rect2i(0, 0, ViewConfig.VIEW_W, ViewConfig.VIEW_H).encloses(r), "on screen: %s" % r)
	# Bushes fit in the grass between the panels and the verges.
	var bush := atlas.frame_size(ViewConfig.BUSH).x * ViewConfig.BUSH_SCALE
	var at := Road.bush_x(cfg, true, bush)
	var grass := Road.grass_ends(cfg)
	assert_between(at.x, ViewConfig.PANEL_LEFT.end.x, grass.x - bush)
	assert_between(at.y, grass.y, ViewConfig.PANEL_RIGHT.position.x - bush)


func test_text_sizes_are_multiples_of_8() -> void:
	for size: int in ViewConfig.TEXT_SIZES:
		assert_eq(size % 8, 0, "text size %d" % size)
	# Every text size the view's code names is one of TEXT_SIZES.
	var named := RegEx.create_from_string("\\bTEXT_[A-Z]+\\b")
	var script: Script = ViewConfig
	var constants := script.get_script_constant_map()
	var unknown: Array = []
	for path: String in _view_scripts():
		for found: RegExMatch in named.search_all(FileAccess.get_file_as_string(path)):
			var name := found.get_string()
			if name != "TEXT_SIZES" and not ViewConfig.TEXT_SIZES.has(constants.get(name)):
				unknown.append("%s in %s" % [name, path])
	assert_eq(unknown, [], "text sizes that are not in TEXT_SIZES")


## Text fits where it is drawn: the HUD's widest values in their panels, overlay lines in their panels, messages on
## the road, the controls in their boxes, the title and prompt on the screen.
func test_text_fits_its_box() -> void:
	var font := atlas.font
	var small := ViewConfig.TEXT_SMALL
	var medium := ViewConfig.TEXT_MEDIUM
	var panel_w := ViewConfig.PANEL_LEFT.size.x
	for value: String in ["000000", "999999", "HIGH", "SCORE", "LOW FUEL"]:
		assert_lt(Draw.text_width(font, value, medium if value != "LOW FUEL" else small), panel_w - 8, value)
	assert_lt(Draw.text_width(font, "400", medium) + small + Draw.text_width(font, "km/h", small), panel_w - 8)
	var w := World.new(cfg, 1)
	w.player().score = 999999
	for phase: int in [World.PAUSED, World.STAGE_CLEAR, World.GAME_OVER]:
		w.phase = phase
		var overlay := Hud.overlay_for(w, 999999)
		var width: int = overlay[2]
		assert_lt(Draw.text_width(font, overlay[0], medium), width - 2 * ViewConfig.OVERLAY_PADDING, overlay[0])
		for line: String in overlay[1]:
			assert_lt(Draw.text_width(font, line, small), width - 2 * ViewConfig.OVERLAY_PADDING, line)
		var r := Hud.overlay_rect((overlay[1] as Array).size(), width)
		assert_true(Rect2i(0, 0, ViewConfig.VIEW_W, ViewConfig.VIEW_H).encloses(r), "%s panel on screen" % overlay[0])
	var road_w := int(cfg.road_right - cfg.road_left)
	for events: int in [World.EV_SPIN, World.EV_CRASH, World.EV_SKID, World.EV_PICKUP, World.EV_PASS]:
		for line: String in Hud.message_lines(cfg, Game.message_for(events)):
			assert_lt(Draw.text_width(font, line, medium), road_w + 1, line)
	var box_w := ViewConfig.CONTROLS_LEFT.size.x - 2 * ViewConfig.CONTROLS_PADDING
	for line: String in ViewConfig.CONTROLS_KEYBOARD + ViewConfig.CONTROLS_PAD:
		assert_lt(Draw.text_width(font, line, small), box_w + 1, line)
	var last_line := ViewConfig.CONTROLS_LEFT.position.y + ViewConfig.CONTROLS_LINES_DY
	last_line += (ViewConfig.CONTROLS_KEYBOARD.size() - 1) * ViewConfig.CONTROLS_LINE_STEP + small
	assert_lt(last_line, ViewConfig.CONTROLS_LEFT.end.y - 4, "the controls end inside their box")
	assert_lt(Draw.text_width(font, ViewConfig.TITLE, ViewConfig.TEXT_HUGE), ViewConfig.VIEW_W)
	assert_lt(Draw.text_width(font, ViewConfig.PROMPT, small), ViewConfig.VIEW_W)


func test_the_title_car_stands_in_the_start_lane() -> void:
	var box := TitleView.car_box(cfg)
	assert_eq(box.position.x, 291)
	assert_eq(box.size, Vector2i(14, 24))
	assert_false(box.intersects(ViewConfig.START_BUTTON))
	assert_lt(box.end.y, ViewConfig.PROMPT_BAND_Y + 1)


func test_the_overlay_follows_the_phase() -> void:
	var w := World.new(cfg, 1)
	assert_eq(Hud.overlay_for(w, 0), [])
	w.phase = World.PAUSED
	assert_eq(Hud.overlay_for(w, 0)[0], "PAUSED")
	w.phase = World.GAME_OVER
	w.player().score = 1250
	assert_eq(Hud.overlay_for(w, 4000)[1], ["Score 1250", "Best 4000", "", "ENTER / A  retry", "ESC / START  title"])
	w.phase = World.STAGE_CLEAR
	w.player().fuel = 40.9
	var stage_clear := Hud.overlay_for(w, 0)
	assert_eq(stage_clear[0], "STAGE 1 CLEAR")
	assert_has(stage_clear[1], "Fuel bonus +1200")
	assert_has(stage_clear[1], "Next: stage 2, busier road")


## Phaser's handleEvents(): one message per step, in this order of priority; none with a game over.
func test_event_messages_follow_phasers_priority() -> void:
	assert_eq(Game.message_for(World.EV_SPIN | World.EV_CRASH), "SPIN OUT!")
	assert_eq(Game.message_for(World.EV_CRASH), "CRASH!")
	assert_eq(Game.message_for(World.EV_SKID | World.EV_PASS), "OIL! STEER INTO THE SLIDE")
	assert_eq(Game.message_for(World.EV_PICKUP | World.EV_PASS), "FUEL!")
	assert_eq(Game.message_for(World.EV_PASS), "PASS +50")
	assert_eq(Game.message_for(World.EV_BUMP), "")
	assert_eq(Game.message_for(World.EV_GAME_OVER | World.EV_CRASH), "")
	assert_eq(Hud.message_lines(cfg, "OIL! STEER INTO THE SLIDE"), PackedStringArray(["OIL! STEER INTO", "THE SLIDE"]))


static func _view_scripts() -> Array:
	var out: Array = []
	for name in DirAccess.get_files_at("res://scripts/view"):
		if name.ends_with(".gd"):
			out.append("res://scripts/view/" + name)
	return out
