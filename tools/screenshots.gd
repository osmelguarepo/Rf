extends "res://tools/tool_base.gd"
## Screenshots of the game for docs/screenshots/ (docs/GODOT_PLAN.md §6). Needs a display and a renderer.
## tools/run_tool.sh screenshots [--out=DIR --seed=N] imports the project and runs this command, then fails on any
## ERROR line of the output, as tools/test.sh does:
##
##   xvfb-run -a -s "-screen 0 1920x1080x24" godot --rendering-driver opengl3 --fixed-fps 60 --path . \
##       -s res://tools/screenshots.gd [-- --out=DIR --seed=N]
##
## It plays the real game with key events (Enter, X held, Esc; the tool_base.gd autopilot steers with the arrow
## keys) and saves:
##   01-title.png        the title screen;
##   02-game.png         a game in high gear, once several cars are on screen;
##   03-pause.png        the pause panel, one tick after 02 (the Esc sent after 02 reaches the game a frame later);
##   04-game-over.png    the game-over panel (the tank set to 0.1, so it runs dry within 6 ticks);
##   05-stage-clear.png  the stage-clear panel (the car set just short of the goal);
##   06-skid-low-fuel.png  staged: a skid (the 45-degree frame) with its message, the low-fuel warning, a rainbow fuel
##                       car, a truck and an oil patch, all at once.
## Each PNG is the 640x360 viewport scaled 2x with Nearest, so its pixels are the game's pixels (tools/scalecheck.gd
## checks that the window shows exactly the viewport). Exit code 0 when every shot was saved and no error was logged
## until the game's nodes were freed (tools/tool_base.gd).

const Hud := preload("res://scripts/view/hud.gd")
const ViewConfig := preload("res://scripts/view/view_config.gd")
const Car := preload("res://scripts/sim/car.gd")

const OUT_DEFAULT := "res://docs/screenshots"
const SEED_DEFAULT := 20261015
## Give up waiting for traffic after this many frames of driving and take the shot anyway.
const TRAFFIC_WAIT := 3600
const SCALE := 2
const SHOTS := 6

var out_dir: String
## The step of the script below, and the frame it started.
var _stage: int = 0
var _since: int = 0
var _saved: Array[String] = []


func _initialize() -> void:
	if not begin():
		finish(1)
		return
	if DisplayServer.get_name() == "headless":
		printerr("screenshots: needs a display and a renderer (xvfb-run, --rendering-driver opengl3), not --headless")
		finish(1)
		return
	out_dir = ProjectSettings.globalize_path(user_arg("out", OUT_DEFAULT))
	DirAccess.make_dir_recursive_absolute(out_dir)
	start_app(user_arg("seed", str(SEED_DEFAULT)).to_int())


func _process(_delta: float) -> bool:
	frame += 1
	var waited := frame - _since
	var w := world()
	match _stage:
		0:  # The title, with the prompt at full brightness (it dims after half a second).
			if waited == 20:
				_shot("01-title")
				tap(KEY_ENTER)
				_next()
		1:  # Driving: hold X (high gear), keep clear of trouble, and wait for a busy road.
			if w != null and waited == 2:
				key(KEY_X, true)
			autopilot()
			if w != null and w.phase == World.GAME_OVER:
				tap(KEY_ENTER)
			elif waited > 300 and (_busy_road() or waited > TRAFFIC_WAIT):
				hold_steer(KEY_NONE)
				_shot("02-game")
				tap(KEY_ESCAPE)
				_next()
		2:  # Paused.
			if waited == 4 and _expect(w != null and w.phase == World.PAUSED, "the game did not pause"):
				_shot("03-pause")
				tap(KEY_ESCAPE)
				_next()
		3:  # Run the tank dry.
			if waited == 4 and _expect(w != null and w.phase == World.RUNNING, "the game did not resume"):
				w.player().fuel = 0.1
			if w != null and w.phase == World.GAME_OVER and waited > 30:
				_shot("04-game-over")
				tap(KEY_ENTER)
				_next()
		4:  # A new game, put just short of the goal.
			if waited == 120 and _expect(w != null and w.phase == World.RUNNING, "no new game after Enter"):
				w.player().y_world = w.goal - 2.0
			if w != null and w.phase == World.STAGE_CLEAR and waited > 150:
				_shot("05-stage-clear")
				tap(KEY_ENTER)
				_next()
		5:  # Stage 2: stage a skid, low fuel and every kind of traffic, timed so that at the shot the low-fuel warning
			# is lit and the fuel car's rainbow is at magenta, a colour no other car has.
			if w != null and waited > 240 and w.phase == World.RUNNING and _good_moment(w.stage_ticks + 2):
				_stage_details(w)
				_next()
		6:
			if waited == 2:
				_shot("06-skid-low-fuel")
				_next()
		7:
			var saved_line := "screenshots: saved %s in %s" % [", ".join(_saved), out_dir]
			if _saved.size() == SHOTS:
				finish(0, saved_line)
			else:
				print(saved_line)
				finish(1)
	if frame > 20000:
		printerr("screenshots: stuck at step %d" % _stage)
		finish(1)
	return false


## Fails the run with a message unless ok.
func _expect(ok: bool, what: String) -> bool:
	if not ok:
		printerr("screenshots: ", what)
		finish(1)
	return ok


func _next() -> void:
	_stage += 1
	_since = frame


## Three or more cars on screen ahead of the player, the player in plain view (not blinking or skidding) and some
## points already scored.
func _busy_road() -> bool:
	var w := world()
	if w == null or w.phase != World.RUNNING:
		return false
	var p := w.player()
	if p.invulnerable > 0 or p.is_skidding() or p.score == 0:
		return false
	var cars := 0
	for c: Traffic in w.traffic:
		var top := w.screen_y(c.y_world)
		if c.is_car() and top > 24.0 and top < 260.0:
			cars += 1
	return cars >= 3


## True at a stage tick when the low-fuel warning (it blinks every WARN_BLINK_TICKS) is lit and the rainbow's hue is
## between 280 and 320 degrees.
static func _good_moment(stage_tick: int) -> bool:
	var lit := floori(stage_tick / float(Hud.WARN_BLINK_TICKS)) % 2 == 0
	var hue := posmod(stage_tick * ViewConfig.RAINBOW_DEGREES_PER_TICK, 360)
	return lit and hue >= 280 and hue <= 320


## Puts a fuel car, a truck, a yellow car and an oil patch around the player, sends it into a skid with its message,
## and leaves 15 units in the tank.
func _stage_details(w: World) -> void:
	var p := w.player()
	var lane := Traffic.lane_of(w.cfg, p.x, p.w)
	var side := 1 if lane < w.cfg.lane_count - 2 else -1
	_place(w, Config.KIND_FUEL_CAR, lane + side, 228.0, Config.FUEL_CAR_SPEED)
	_place(w, Config.KIND_TRUCK, lane + 2 * side, 48.0, Config.TRUCK_SPEED)
	_place(w, Config.KIND_YELLOW, lane - side, 200.0, 100.0)
	_place(w, Config.KIND_OIL, lane, w.anchor + p.h + 4.0, 0.0)
	p.fuel = 15.0
	Car.start_skid(w.cfg, p, side)
	var screen := game()
	screen.message = "OIL! STEER INTO THE SLIDE"
	screen.message_time = 1.0
	hold_steer(KEY_NONE)


## A traffic object of a kind in a lane (clamped to the road), with its top at a screen y.
static func _place(w: World, kind: int, lane: int, screen_top: float, kmh: float) -> void:
	var c := Traffic.new()
	c.id = 900 + w.traffic.size()
	c.kind = kind
	c.w = w.cfg.kind_w[kind]
	c.h = w.cfg.kind_h[kind]
	c.x = Traffic.lane_x(w.cfg, clampi(lane, 0, w.cfg.lane_count - 1), c.w)
	c.y_world = w.camera_y + w.anchor - screen_top
	c.kmh = kmh
	c.lane_timer = 1000000
	w.traffic.append(c)


func _shot(name: String) -> void:
	var image := viewport_image()
	image.resize(image.get_width() * SCALE, image.get_height() * SCALE, Image.INTERPOLATE_NEAREST)
	var path := out_dir.path_join(name + ".png")
	if image.save_png(path) == OK:
		_saved.append(name + ".png")
	else:
		printerr("screenshots: could not save ", path)
