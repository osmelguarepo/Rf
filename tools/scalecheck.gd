extends "res://tools/tool_base.gd"
## Checks that the window shows the 640x360 viewport scaled by a whole number with Nearest filtering and nothing
## else: every window pixel equals its viewport pixel, and the bars around the picture are black (docs/GODOT_PLAN.md
## §6). Needs a display and a renderer; run it once per window size:
##
##   for r in 1280x800 1920x1080 1366x768; do
##     xvfb-run -a -s "-screen 0 1920x1080x24" godot --rendering-driver opengl3 --fixed-fps 60 --resolution $r \
##         --path . -s res://tools/scalecheck.gd
##   done
##
## It compares two still pictures: the title screen, and a game paused after a few seconds of driving (so cars, road,
## HUD and the pause panel are all on screen). The window's image is read back from the screen
## (DisplayServer.screen_get_image()) at the window's position. Prints one line per picture and exits 0 when every
## pixel matches at the expected scale: floor(min(width / 640, height / 360)), which must be at least 2.
##
## Inside the viewport it also checks the Nearest filtering of sprites: on the title, every opaque pixel of the
## player's car must be its atlas pixel, exactly, as a 2x2 block.

const TitleView := preload("res://scripts/view/title_view.gd")
const Draw := preload("res://scripts/view/draw.gd")
const ViewConfig := preload("res://scripts/view/view_config.gd")

const SEED := 20261015
const VIEW := Vector2i(640, 360)

var _stage := 0
var _since := 0
var _failed := false
var _scale := 0


func _initialize() -> void:
	if not begin():
		finish(1)
		return
	if DisplayServer.get_name() == "headless":
		printerr("scalecheck: needs a display and a renderer (xvfb-run, --rendering-driver opengl3), not --headless")
		finish(1)
		return
	start_app(SEED)


func _process(_delta: float) -> bool:
	frame += 1
	var waited := frame - _since
	var w := world()
	match _stage:
		0:  # The title, inside the first half second, while its prompt is steady.
			if waited == 12:
				_check("title")
				_check_sprite()
				tap(KEY_ENTER)
				_next()
		1:  # Drive for a few seconds, then pause, which freezes the picture.
			if w != null and waited == 2:
				key(KEY_X, true)
			autopilot()
			if waited == 400:
				hold_steer(KEY_NONE)
				tap(KEY_ESCAPE)
				_next()
		2:
			if waited == 10:
				if w == null or w.phase != World.PAUSED:
					_fail("the game did not pause")
				_check("game")
				_next()
		3:
			finish(1 if _failed else 0)
	return false


func _next() -> void:
	_stage += 1
	_since = frame


func _fail(what: String) -> void:
	_failed = true
	printerr("scalecheck: FAIL ", what)


## Compares the window with the viewport scaled by the stretch transform.
func _check(name: String) -> void:
	var size := DisplayServer.window_get_size()
	var pos := DisplayServer.window_get_position()
	var asked := _resolution_argument()
	if asked != Vector2i.ZERO and asked != size:
		_fail("the window is %s, not the %s asked for" % [size, asked])
	var expected_scale := mini(floori(size.x / float(VIEW.x)), floori(size.y / float(VIEW.y)))
	var xform := root.get_final_transform()
	var s := roundi(xform.x.x)
	var offset := Vector2i(roundi(xform.origin.x), roundi(xform.origin.y))
	if xform.x.x != float(s) or xform.y.y != float(s) or xform.x.y != 0.0 or xform.y.x != 0.0:
		_fail("the stretch transform is not a whole-number scale: %s" % xform)
	if Vector2(offset) != xform.origin:
		_fail("the picture does not start on a whole pixel: %s" % xform.origin)
	if s != expected_scale or s < 2:
		_fail("scale %d at %s; expected %d (and at least 2)" % [s, size, expected_scale])

	var viewport := viewport_image()
	viewport.convert(Image.FORMAT_RGB8)
	if viewport.get_size() != VIEW:
		_fail("the viewport is %s, not %s" % [viewport.get_size(), VIEW])
	var scaled := viewport.duplicate() as Image
	scaled.resize(VIEW.x * s, VIEW.y * s, Image.INTERPOLATE_NEAREST)
	var expected := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGB8)
	expected.fill(Color.BLACK)
	expected.blit_rect(scaled, Rect2i(Vector2i.ZERO, scaled.get_size()), offset)

	var screen := DisplayServer.screen_get_image(DisplayServer.window_get_current_screen())
	if screen == null or not Rect2i(Vector2i.ZERO, screen.get_size()).encloses(Rect2i(pos, size)):
		_fail("could not read the window back from the screen")
		return
	var window := screen.get_region(Rect2i(pos, size))
	window.convert(Image.FORMAT_RGB8)
	var differing := _differing_pixels(window, expected)
	print("scalecheck %dx%d %s: scale %d, picture at %s, %d of %d pixels differ" % [
		size.x, size.y, name, s, offset, differing, size.x * size.y
	])
	if differing != 0:
		_fail("%s: %d pixels differ" % [name, differing])


## The title's car against its atlas frame: each opaque texture pixel is a 2x2 block of exactly its colour.
func _check_sprite() -> void:
	var tex := app.atlas.frame(ViewConfig.PLAYER["frame"]) as AtlasTexture
	var sheet := app.atlas.texture.get_image()
	if tex == null or sheet == null:
		_fail("could not read the atlas")
		return
	sheet.convert(Image.FORMAT_RGBA8)
	var viewport := viewport_image()
	viewport.convert(Image.FORMAT_RGBA8)
	var region := Rect2i(tex.region)
	var box := TitleView.car_box(Config.standard())
	var scale := ViewConfig.SPRITE_SCALE
	var at := Draw.place_on_hitbox(region.size, ViewConfig.PLAYER["shadow"], scale, box.position, box.size)
	var checked := 0
	var wrong := 0
	for y in region.size.y:
		for x in region.size.x:
			var texel := sheet.get_pixelv(region.position + Vector2i(x, y))
			if texel.a8 != 255:
				continue
			for dy in scale:
				for dx in scale:
					var pixel := viewport.get_pixel(at.x + x * scale + dx, at.y + y * scale + dy)
					checked += 1
					if pixel.r8 != texel.r8 or pixel.g8 != texel.g8 or pixel.b8 != texel.b8:
						wrong += 1
	print("scalecheck sprite: %d of %d pixels of the title's car differ from its atlas frame at %dx" % [wrong, checked, scale])
	if wrong != 0 or checked == 0:
		_fail("the car is not its atlas frame, pixel for pixel")


static func _differing_pixels(a: Image, b: Image) -> int:
	var x := a.get_data()
	var y := b.get_data()
	if x == y:
		return 0
	if x.size() != y.size():
		return a.get_width() * a.get_height()
	var count := 0
	for i in range(0, x.size(), 3):
		if x[i] != y[i] or x[i + 1] != y[i + 1] or x[i + 2] != y[i + 2]:
			count += 1
	return count


## The size given with --resolution WxH on the command line, or (0, 0).
static func _resolution_argument() -> Vector2i:
	var args := OS.get_cmdline_args()
	var at := args.find("--resolution")
	if at < 0 or at + 1 >= args.size():
		return Vector2i.ZERO
	var parts := args[at + 1].split("x")
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return Vector2i.ZERO
	return Vector2i(parts[0].to_int(), parts[1].to_int())
