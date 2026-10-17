extends "res://tools/tool_base.gd"
## The smoke test (docs/GODOT_PLAN.md §6): plays the real game, from its main scene, with real input events on a
## fixed timeline, and checks what happened. Headless, no renderer needed. Run it with tools/run_tool.sh, which
## imports the project, runs the plan's command and fails on any ERROR line of the output, as tools/test.sh does
## (CI runs it this way):
##
##   tools/run_tool.sh smoke
##   timeout 300 godot --headless --fixed-fps 60 --path . -s res://tools/smoke.gd -- --scenario=1p --frames=10800
##
## Scenario 1p, frame by frame (--fixed-fps 60 makes every frame exactly one simulation step). Every event goes
## through Input.parse_input_event(), as the keyboard and joypad drivers send them, and reaches the game on the next
## frame through App._input().
##
## The keyboard:
##   30          Enter on the title: the game starts.
##   40          X goes down and stays down: high gear and throttle.
##   every 120   the steering changes: left, none, right, none, ... (the arrow keys).
##   600, 660    Esc: pause, then resume.
##   900         the application loses focus (NOTIFICATION_APPLICATION_FOCUS_OUT): the game must pause.
##   +13         focus comes back (NOTIFICATION_APPLICATION_FOCUS_IN): the game must stay paused.
##   +76         Esc resumes, and X and the steering key go down again: losing focus let go of every key.
##   game over   one second later, Enter: a new game (retry). The same after a stage clear, to go on.
## Then a joypad (device 0), from 10 s after that first retry (T):
##   T           the keys go up: the car coasts in low gear.
##   T+3         A goes down and stays down: high gear and throttle again.
##   every 120   the steering changes: left stick left, none, stick right, none, D-pad left, none, D-pad right, none.
##   T+600, +60  Start: pause, then resume.
##   T+1200      the tank is set to 0.1 (as tools/screenshots.gd does for its game-over picture), so the game ends
##               within six ticks whatever the traffic does; again at T+2400.
##   game over   one second later: at the pad's first game over, Start (back to the title), then half a second later
##               A (a new game); at every later one, A (a retry). After a stage clear, A.
## An action meant for a running game (a pause, the focus loss, the switch to the pad, emptying the tank) waits for a
## frame where the game is running, and the actions after it move along with it.
##
## It passes (exit 0) when: the game screen was reached; Esc paused and resumed; losing focus paused and getting it
## back did not resume; Enter retried after a game over; the pad's A held high gear and throttle; its stick and its
## D-pad each steered the car left and right (the car moved that way while not skidding); Start paused, resumed, and
## went from a game over to the title; A started a game from the title and retried after a game over; and no error
## was logged from the start until the game's nodes were freed (tools/tool_base.gd). The exit code does not cover what
## the engine prints after that, while it shuts down (leaked RIDs or resources): tools/run_tool.sh checks those lines.
## Phase B adds scenarios (B3).

const Car := preload("res://scripts/sim/car.gd")
const Held := preload("res://scripts/input/held.gd")
const Keyboard := preload("res://scripts/input/keyboard.gd")

const SEED := 1
const ENTER_AT := 30
const X_AT := 40
const STEER_EVERY := 120
const STEER_KEYS: Array[Key] = [KEY_LEFT, KEY_NONE, KEY_RIGHT, KEY_NONE]
const PAUSE_AT := 600
const FOCUS_OUT_AT := 900
## The joypad's device, and when it takes over: frames after the first retry with Enter.
const PAD := 0
const PAD_AFTER_RETRY := 600
## The pad's steering per STEER_EVERY frames: [control, direction]. The directions are those of STEER_KEYS.
const PAD_STEER_CYCLE := [
	["stick", -1], ["", 0], ["stick", 1], ["", 0], ["D-pad", -1], ["", 0], ["D-pad", 1], ["", 0],
]
## How far the stick is pushed (it counts beyond 0.5).
const STICK_PUSH := 0.9
## Frames to wait at a game over or a stage clear, and on the title, before pressing.
const PANEL_WAIT := 60
const TITLE_WAIT := 30
## Frames after an event before its effect is checked.
const SETTLE := 3
const PROGRESS_EVERY := 1800

## Sequences of actions: [frames after the previous action, action].
const START := [[ENTER_AT, "enter on title"], [SETTLE, "check game"], [X_AT - ENTER_AT - SETTLE, "x down"]]
const ESC_PAUSE := [[0, "esc pause"], [SETTLE, "check paused"], [60 - SETTLE, "esc resume"], [SETTLE, "check resumed"]]
const FOCUS := [
	[0, "focus out"], [SETTLE, "check focus pause"], [10, "focus in"], [SETTLE, "check still paused"],
	[60, "resume after focus"], [SETTLE, "check resumed after focus"],
]
const PAD_TAKEOVER := [[0, "keys up"], [SETTLE, "check coasting, A down"], [SETTLE, "check A held"]]
const START_PAUSE := [
	[0, "start pause"], [SETTLE, "check paused by Start"], [60 - SETTLE, "start resume"],
	[SETTLE, "check resumed by Start"],
]
const PAD_PAUSE_AFTER := 600
## Frames after the takeover when the tank is set to 0.1, and the fuel left then.
const EMPTY_TANK_AFTER: Array[int] = [1200, 2400]
const FUEL_LEFT := 0.1
## At a game over: Enter (keyboard); Start, then A on the title (the pad's first); A (the pad's later ones).
const ENTER_RETRY := [[0, "tap enter"], [SETTLE, "check retry by Enter"]]
const START_TO_TITLE := [
	[0, "tap start"], [SETTLE, "check title"], [TITLE_WAIT, "tap a"], [SETTLE, "check game from title"],
]
const A_RETRY := [[0, "tap a"], [SETTLE, "check retry by A"]]
## Actions that wait for a running game.
const NEEDS_RUNNING := ["esc pause", "focus out", "keys up", "start pause", "empty tank"]

var frames: int = 10800
var scenario: String = "1p"

# What was seen; _report() checks it.
var reached_game := false
var paused_by_esc := false
var resumed_by_esc := false
var paused_by_focus := false
var stayed_paused_on_focus_in := false
var resumed_after_focus := false
var retries_by_enter := 0
var coasted_without_keys := false
var held_by_a := false
## "stick left", "stick right", "D-pad left", "D-pad right": the car moved that way while the pad steered it so.
var steered := {}
var paused_by_start := false
var resumed_by_start := false
var title_by_start := false
var game_by_a := false
var retries_by_a := 0
var game_overs := 0
var stage_clears := 0

var _failures: Array[String] = []
## Running sequences: {"steps": [[delay, action], ...], "next": index of the next action, "at": its frame}.
var _sequences: Array[Dictionary] = []
## True once the joypad drives; the keyboard is idle from then on.
var _pad := false
## What the pad's steering holds now: [control, direction].
var _pad_steer: Array = ["", 0]
var _panel_since := -1
## The screen, world and stage before a press that should start a new game or the next stage.
var _screen_before: Node = null
var _world_before: World = null
var _stage_before := 0
## The player's car on the last frame, to see which way it moved.
var _last_world: World = null
var _last_x := 0.0
var _last_skidding := true


func _initialize() -> void:
	if not begin():
		finish(1)
		return
	frames = user_arg("frames", str(frames)).to_int()
	scenario = user_arg("scenario", scenario)
	if scenario != "1p":
		printerr("smoke: unknown scenario %s (only 1p in phase A)" % scenario)
		finish(1)
		return
	start_app(SEED)
	_start_sequence(START)
	_start_sequence(ESC_PAUSE, PAUSE_AT)
	_start_sequence(FOCUS, FOCUS_OUT_AT)


func _process(_delta: float) -> bool:
	frame += 1
	_run_sequences()
	if frame >= STEER_EVERY and frame % STEER_EVERY == 0:
		_steer_segment(floori(frame / float(STEER_EVERY)))
	_watch_pad_steering()
	_watch_game()
	if frame % PROGRESS_EVERY == 0:
		_progress()
	if frame >= frames:
		_report()
	return false


# --- Sequences of actions --------------------------------------------------------------------------------------------


## Starts a sequence: its first action `delay` frames from now plus that action's own delay.
func _start_sequence(steps: Array, delay: int = 0) -> void:
	_sequences.append({"steps": steps, "next": 0, "at": frame + delay + int(steps[0][0])})


## Runs the actions that are due. An action meant for a running game waits while the game is not running, and the
## rest of its sequence moves along with it.
func _run_sequences() -> void:
	for sequence: Dictionary in _sequences.duplicate():
		var steps: Array = sequence["steps"]
		while sequence["next"] < steps.size() and frame >= sequence["at"]:
			var action: String = steps[sequence["next"]][1]
			if NEEDS_RUNNING.has(action) and not _running():
				sequence["at"] = frame + 1
				break
			_do(action)
			sequence["next"] += 1
			if sequence["next"] < steps.size():
				sequence["at"] = frame + int(steps[sequence["next"]][0])
		if sequence["next"] >= steps.size():
			_sequences.erase(sequence)


func _do(action: String) -> void:
	var w := world()
	match action:
		"enter on title":
			if not on_title():
				_fail("the title screen was not showing at frame %d" % frame)
			_screen_before = app.current_screen()
			tap(KEY_ENTER)
		"check game":
			reached_game = game() != null
			if not reached_game:
				_fail("Enter on the title did not start a game")
		"x down":
			key(KEY_X, true)
		"esc pause", "esc resume":
			tap(KEY_ESCAPE)
		"check paused":
			paused_by_esc = _expect_phase(w, World.PAUSED, "Esc did not pause")
		"check resumed":
			resumed_by_esc = _expect_phase(w, World.RUNNING, "Esc did not resume") and paused_by_esc
		"focus out":
			notification(NOTIFICATION_APPLICATION_FOCUS_OUT)
		"check focus pause":
			paused_by_focus = _expect_phase(w, World.PAUSED, "losing focus did not pause")
		"focus in":
			notification(NOTIFICATION_APPLICATION_FOCUS_IN)
		"check still paused":
			stayed_paused_on_focus_in = _expect_phase(w, World.PAUSED, "getting focus back resumed the game by itself")
		"resume after focus":
			# Losing focus let go of every key (Godot releases held keys then, as the Phaser version did on blur),
			# so the player presses Esc to resume and holds X and the steering key again.
			tap(KEY_ESCAPE)
			key(KEY_X, true)
			if _steer_key != KEY_NONE:
				key(_steer_key, true)
		"check resumed after focus":
			resumed_after_focus = _expect_phase(w, World.RUNNING, "Esc did not resume after the focus pause") and paused_by_focus
		"tap enter":
			tap(KEY_ENTER)
		"check retry by Enter":
			if _expect_new_game(true, "Enter after a game over"):
				retries_by_enter += 1
				if retries_by_enter == 1:
					_start_sequence(PAD_TAKEOVER, PAD_AFTER_RETRY)
		"check next stage":
			if w == null or w.stage != _stage_before + 1 or w.phase != World.RUNNING:
				_fail("no next stage after the stage clear (frame %d)" % frame)
		"keys up":
			key(KEY_X, false)
			hold_steer(KEY_NONE)
			_pad = true
			_start_sequence(START_PAUSE, PAD_PAUSE_AFTER)
			for after: int in EMPTY_TANK_AFTER:
				_start_sequence([[0, "empty tank"]], after)
		"check coasting, A down":
			coasted_without_keys = Keyboard.held() == 0 and w != null and w.player().gear == Car.GEAR_LOW
			if not coasted_without_keys:
				_fail("the car did not drop to low gear when the keys went up (frame %d)" % frame)
			pad_button(PAD, JOY_BUTTON_A, true)
		"check A held":
			var both := Held.ACCEL | Held.HIGH_GEAR
			held_by_a = (
				app.input.pads.devices.has(PAD) and Keyboard.held() == 0 and (app.input.held() & both) == both
				and w != null and w.player().gear == Car.GEAR_HIGH
			)
			if not held_by_a:
				_fail("the pad's A did not give high gear and throttle (frame %d)" % frame)
		"empty tank":
			w.player().fuel = FUEL_LEFT
		"start pause", "start resume", "tap start":
			pad_tap(PAD, JOY_BUTTON_START)
		"check paused by Start":
			paused_by_start = _expect_phase(w, World.PAUSED, "Start did not pause")
		"check resumed by Start":
			resumed_by_start = _expect_phase(w, World.RUNNING, "Start did not resume") and paused_by_start
		"tap a":
			# A is held while the pad drives: it goes up and down again, and stays down.
			pad_button(PAD, JOY_BUTTON_A, false)
			pad_button(PAD, JOY_BUTTON_A, true)
		"check title":
			title_by_start = on_title()
			if not title_by_start:
				_fail("Start at a game over did not go to the title (frame %d)" % frame)
		"check game from title":
			game_by_a = _expect_new_game(false, "A on the title")
		"check retry by A":
			if _expect_new_game(true, "A after a game over"):
				retries_by_a += 1
		_:
			_fail("unknown action %s" % action)


func _running() -> bool:
	var w := world()
	return w != null and w.phase == World.RUNNING


func _expect_phase(w: World, phase: int, what: String) -> bool:
	var ok := w != null and w.phase == phase
	if not ok:
		_fail("%s (frame %d)" % [what, frame])
	return ok


## A new running game after a press: on the same game screen (a retry) or on a new one (from the title).
func _expect_new_game(same_screen: bool, what: String) -> bool:
	var screen := game()
	var ok := (
		screen != null and (screen == _screen_before) == same_screen and world() != _world_before
		and world().phase == World.RUNNING
	)
	if not ok:
		_fail("%s did not start a new game (frame %d)" % [what, frame])
	return ok


# --- Steering --------------------------------------------------------------------------------------------------------


## The steering of one STEER_EVERY-frame segment: the arrow keys until the pad takes over, then the pad.
func _steer_segment(index: int) -> void:
	if not _pad:
		hold_steer(STEER_KEYS[index % STEER_KEYS.size()])
		return
	var segment: Array = PAD_STEER_CYCLE[index % PAD_STEER_CYCLE.size()]
	var control: String = _pad_steer[0]
	var direction: int = _pad_steer[1]
	if control == "stick" and direction != 0:
		pad_axis(PAD, JOY_AXIS_LEFT_X, 0.0)
	elif control == "D-pad" and direction != 0:
		pad_button(PAD, _dpad(direction), false)
	control = segment[0]
	direction = segment[1]
	if control == "stick" and direction != 0:
		pad_axis(PAD, JOY_AXIS_LEFT_X, STICK_PUSH * direction)
	elif control == "D-pad" and direction != 0:
		pad_button(PAD, _dpad(direction), true)
	_pad_steer = [control, direction]


static func _dpad(direction: int) -> JoyButton:
	return JOY_BUTTON_DPAD_LEFT if direction < 0 else JOY_BUTTON_DPAD_RIGHT


## While the pad steers: notes the control and direction when the car moved that way from one frame to the next
## without skidding on either (a skid moves the car by itself; steering does not move a skidding car).
func _watch_pad_steering() -> void:
	var w := world()
	if w == null or w.phase != World.RUNNING:
		_last_world = null
		return
	var p := w.player()
	var direction: int = _pad_steer[1]
	if _pad and direction != 0 and w == _last_world and not _last_skidding and not p.is_skidding():
		if (p.x - _last_x) * direction > 0.0:
			steered["%s %s" % [_pad_steer[0], "left" if direction < 0 else "right"]] = true
	_last_world = w
	_last_x = p.x
	_last_skidding = p.is_skidding()


# --- Game overs and stage clears -------------------------------------------------------------------------------------


## Game overs and stage clears: count them, wait a second, and press (see the timeline).
func _watch_game() -> void:
	var w := world()
	if w == null or not (w.phase == World.GAME_OVER or w.phase == World.STAGE_CLEAR):
		_panel_since = -1
		return
	if _panel_since < 0:
		_panel_since = frame
		if w.phase == World.GAME_OVER:
			game_overs += 1
		else:
			stage_clears += 1
	if frame - _panel_since != PANEL_WAIT:
		return
	_screen_before = game()
	_world_before = w
	_stage_before = w.stage
	if w.phase == World.STAGE_CLEAR:
		_start_sequence([[0, "tap a" if _pad else "tap enter"], [SETTLE, "check next stage"]])
	elif not _pad:
		_start_sequence(ENTER_RETRY)
	elif not title_by_start:
		_start_sequence(START_TO_TITLE)
	else:
		_start_sequence(A_RETRY)


# --- Report ----------------------------------------------------------------------------------------------------------


func _progress() -> void:
	var w := world()
	if w == null:
		print("smoke: frame %d, no game" % frame)
		return
	var p := w.player()
	print("smoke: frame %d, %s, %s, stage %d, tick %d, %d km/h, score %d, fuel %.1f, game overs %d" % [
		frame, "pad" if _pad else "keyboard", World.PHASE_NAMES[w.phase], w.stage, w.tick, roundi(p.speed), p.score,
		p.fuel, game_overs
	])


func _fail(what: String) -> void:
	_failures.append(what)
	printerr("smoke: FAIL ", what)


func _report() -> void:
	if not reached_game:
		_fail("never reached the game screen")
	if not (paused_by_esc and resumed_by_esc):
		_fail("pause and resume with Esc did not both happen")
	if not (paused_by_focus and stayed_paused_on_focus_in and resumed_after_focus):
		_fail("the focus-loss pause was not seen through")
	if retries_by_enter < 1:
		_fail("no game over followed by a retry with Enter")
	if not (coasted_without_keys and held_by_a):
		_fail("the joypad did not take over (the keys up, then A for high gear and throttle)")
	for kind: String in ["stick left", "stick right", "D-pad left", "D-pad right"]:
		if not steered.has(kind):
			_fail("the pad's %s never steered the car" % kind)
	if not (paused_by_start and resumed_by_start):
		_fail("pause and resume with Start did not both happen")
	if not title_by_start:
		_fail("Start never went from a game over to the title")
	if not game_by_a:
		_fail("A never started a game from the title")
	if retries_by_a < 1:
		_fail("no game over followed by a retry with A")
	var logged := errors()
	print("smoke %s keyboard: game started %s, Esc pause/resume %s/%s, focus pause %s, retries with Enter %d" % [
		scenario, reached_game, paused_by_esc, resumed_by_esc, paused_by_focus, retries_by_enter
	])
	print("smoke %s joypad: A held %s, stick left/right %s/%s, D-pad left/right %s/%s, Start pause/resume %s/%s, %s" % [
		scenario, held_by_a, steered.has("stick left"), steered.has("stick right"), steered.has("D-pad left"),
		steered.has("D-pad right"), paused_by_start, resumed_by_start,
		"Start to title %s, A on title %s, retries with A %d" % [title_by_start, game_by_a, retries_by_a]
	])
	print("smoke %s: %d frames, game overs %d, stage clears %d, errors %d" % [
		scenario, frame, game_overs, stage_clears, logged.size()
	])
	var ok := _failures.is_empty() and logged.is_empty()
	print("smoke: %s" % ("PASS" if ok else "FAIL"))
	finish(0 if ok else 1)
