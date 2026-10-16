extends SceneTree
## What tools/smoke.gd, tools/screenshots.gd and tools/scalecheck.gd share. Each tool is a SceneTree run with -s: it
## boots the game's own main scene (scenes/boot.tscn) under itself, drives it with real input events
## (Input.parse_input_event(), delivered on the next frame as a keyboard's would be), counts the errors logged while
## it runs, and ends with finish(code).
##
## Arguments come after "--": --name=value (user_arg()).

const App := preload("res://scripts/app/app.gd")
const World := preload("res://scripts/sim/world.gd")
const Config := preload("res://scripts/sim/config.gd")
const Traffic := preload("res://scripts/sim/traffic.gd")

const BOOT_SCENE := "res://scenes/boot.tscn"
## The autopilot keeps to a lane while it has this much room ahead (px).
const ROOM_ENOUGH := 160.0

var app: App
## Frames since the tool started; _process() of a tool adds one per frame.
var frame: int = 0
var _log := App.ErrorLog.new()
var _finished := false
## The steering key the autopilot holds, or KEY_NONE.
var _steer_key: Key = KEY_NONE


## Starts counting errors. Call first in _initialize(). Returns false (after saying why) if the project has not
## been imported, since the game's art then cannot load: run tools/test.sh, or godot --headless --path . --import.
func begin() -> bool:
	OS.add_logger(_log)
	if not imported():
		printerr("%s: the project is not imported yet; run tools/test.sh or godot --headless --path . --import first" % [
			(get_script() as Script).resource_path.get_file().get_basename()
		])
		return false
	return true


## True when Godot has imported the atlas (its .import file names an imported file that exists).
static func imported() -> bool:
	var config := ConfigFile.new()
	if config.load("res://assets/sprites.png.import") != OK:
		return false
	var path: String = config.get_value("remap", "path", "")
	return not path.is_empty() and FileAccess.file_exists(path)


## Boots the game: an App with a fixed first seed, added to the root, which opens the title screen.
func start_app(seed_value: int) -> App:
	app = (load(BOOT_SCENE) as PackedScene).instantiate() as App
	app.seed_override = seed_value
	root.add_child(app)
	return app


## The value of --name=value after "--", or fallback.
static func user_arg(name: String, fallback: String) -> String:
	var prefix := "--%s=" % name
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with(prefix):
			return argument.trim_prefix(prefix)
	return fallback


## A key going down or up, by physical key code, as the keyboard driver sends it.
static func key(code: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)


## A key pressed and released (both arrive on the next frame, in order).
static func tap(code: Key) -> void:
	key(code, true)
	key(code, false)


## The game screen, or null while another screen is showing.
func game() -> Node:
	var screen := app.current_screen() if app != null else null
	return screen if screen != null and screen.name == "Game" else null


## The world of the game screen, or null.
func world() -> World:
	var screen := game()
	return screen.world if screen != null else null


func on_title() -> bool:
	var screen := app.current_screen() if app != null else null
	return screen != null and screen.name == "Title"


## Errors logged since begin().
func errors() -> PackedStringArray:
	return _log.errors()


## Prints the errors, stops counting and quits with `code`, or 1 if any error was logged.
func finish(code: int) -> void:
	if _finished:
		return
	_finished = true
	var logged := errors()
	OS.remove_logger(_log)
	for line: String in logged:
		printerr("logged error: ", line)
	quit(code if logged.is_empty() else 1)


## Steers with real key presses (Left and Right) towards the lane with the most room ahead, so a scripted drive
## does not end on the first truck. Call once a frame; it lets go of the keys when no game is running.
func autopilot() -> void:
	var w := world()
	if w == null or w.phase != World.RUNNING:
		hold_steer(KEY_NONE)
		return
	var p := w.player()
	var current := Traffic.lane_of(w.cfg, p.x, p.w)
	var best := current
	var best_room := room_ahead(w, current)
	if best_room < ROOM_ENOUGH:
		for offset: int in [-1, 1, -2, 2]:
			var lane := current + offset
			if lane >= 0 and lane < w.cfg.lane_count and room_ahead(w, lane) > best_room + 8.0:
				best = lane
				best_room = room_ahead(w, lane)
	var target := Traffic.lane_x(w.cfg, best, p.w)
	if p.is_skidding():
		# Steer into the slide to recover (steering does not move a skidding car).
		hold_steer(KEY_RIGHT if p.slide_vx > 0.0 else KEY_LEFT)
	elif p.x < target - 1.0:
		hold_steer(KEY_RIGHT)
	elif p.x > target + 1.0:
		hold_steer(KEY_LEFT)
	else:
		hold_steer(KEY_NONE)


## World px from the player's front to the nearest object ahead of (or beside) it whose hitbox reaches into a lane.
static func room_ahead(w: World, lane: int) -> float:
	var p := w.player()
	var left := w.cfg.road_left + w.cfg.lane_width * lane
	var right := left + w.cfg.lane_width
	var room := INF
	for c: Traffic in w.traffic:
		if c.x + c.w <= left or c.x >= right:
			continue
		var rear := c.y_world - c.h
		if c.y_world > p.y_world - p.h:
			room = minf(room, maxf(0.0, rear - p.y_world))
	return room


## Holds one steering key (KEY_LEFT, KEY_RIGHT or KEY_NONE), releasing the other.
func hold_steer(code: Key) -> void:
	if code == _steer_key:
		return
	if _steer_key != KEY_NONE:
		key(_steer_key, false)
	if code != KEY_NONE:
		key(code, true)
	_steer_key = code


## The window's image as the game drew it, before scaling: the root viewport, 640x360.
func viewport_image() -> Image:
	return root.get_texture().get_image()
