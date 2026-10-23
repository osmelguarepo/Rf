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
##   40          X goes down and stays down: nitro and throttle.
##   every 120   the steering changes: left, none, right, none, ... (the arrow keys).
##   600, 660    Esc: pause, then resume.
##   900         the application loses focus (NOTIFICATION_APPLICATION_FOCUS_OUT): the game must pause.
##   +13         focus comes back (NOTIFICATION_APPLICATION_FOCUS_IN): the game must stay paused.
##   +76         Esc resumes, and X and the steering key go down again: losing focus let go of every key.
##   game over   one second later, Enter: a new game (retry). The same after a stage clear, to go on.
## Then a joypad (device 0), from 10 s after that first retry (T):
##   T           the keys go up: the car coasts in low gear.
##   T+3         A goes down and stays down: nitro and throttle again.
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
## back did not resume; Enter retried after a game over; the pad's A held nitro and throttle; its stick and its
## D-pad each steered the car left and right (the car moved that way while not skidding); Start paused, resumed, and
## went from a game over to the title; A started a game from the title and retried after a game over; and no error
## was logged from the start until the game's nodes were freed (tools/tool_base.gd). The exit code does not cover what
## the engine prints after that, while it shuts down (leaked RIDs or resources): tools/run_tool.sh checks those lines.
##
## Scenario versus (B2; tools/run_tool.sh smoke runs it after 1p): a versus match from the title, played with synthetic
## pads (VS_PADS and more) whose events go through Input.parse_input_event() as above. The engine has no GUID for a
## synthetic pad, so the tool gives the seats a GUID source (VS_GUIDS), as the tests do. Step by step (vs_steps()), each
## waiting at most VS_STEP_FRAMES frames for what it expects:
##   title       Down chooses VERSUS and Enter opens the join screen.
##   join        three pads press A: P1, P2 and P3 in that order.
##   bots        Right three times on P1's pad (three bots, as many as fit), once more (still three), Left twice (one).
##   leave       a fourth pad joins (P4) and leaves with B; the bot stays chosen.
##   start       Start on P2's pad: a race of four cars, three of them people's.
##   race        the pads drive (tool_base.gd pad_autopilot()) from here on.
##   pause       Start on P1's pad pauses the round and no car moves for 30 frames; P3's Start resumes it.
##   focus       losing focus pauses it, getting focus back does not resume it, P2's Start does.
##   unplug      P2's pad goes away: its seat is orphaned (NO PAD), the round goes on and its bot drives the car on.
##   replug      the same pad comes back under another device number (the same GUID) and takes its seat back.
##   claim       P3's pad goes away, a new pad connects (another GUID; it takes nothing) and takes the seat with A.
##   round over  P1's tank is emptied, so P1 goes out and the round ends; an A on the round's panel before
##               Config.MATCH_CONFIRM_TICKS steps is ignored, one after them starts round 2.
##   match over  each later round runs 240 steps before P1's tank is emptied, until the match is decided; then A plays
##               a rematch (the next seed, the same seats).
##   title       in the rematch, Start pauses and Back (Select) goes to the title, where every pad leaves its seat.
## It passes when every step saw what it expected and no error was logged. B3 adds the long scenarios of plan §8.

const Held := preload("res://scripts/input/held.gd")
const Keyboard := preload("res://scripts/input/keyboard.gd")
const Seats := preload("res://scripts/input/seats.gd")
const Match := preload("res://scripts/sim/match.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")
const VersusHud := preload("res://scripts/view/versus_hud.gd")

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
	[0, "tap start"], [SETTLE, "check title"], [TITLE_WAIT, "start from title"], [SETTLE, "check game from title"],
]
const A_RETRY := [[0, "tap a"], [SETTLE, "check retry by A"]]
## Actions that wait for a running game.
const NEEDS_RUNNING := ["esc pause", "focus out", "keys up", "start pause", "empty tank"]

## Scenario versus: P1's, P2's and P3's pads; a pad that joins and leaves; a pad that comes along later; and P2's pad
## again under another device number, as a pad that reconnects may get.
const VS_PADS: Array[int] = [20, 21, 22]
const VS_LEAVER := 23
const VS_NEWCOMER := 24
const VS_P2_AGAIN := 31
## The GUIDs the tool's source gives (the engine knows no synthetic pad): P2's pad keeps its GUID under its new number.
const VS_GUIDS := {20: "guid-p1", 21: "guid-p2", 22: "guid-p3", 23: "guid-p4", 24: "guid-new", 31: "guid-p2"}
## Each pad shifts to nitro at its own speed (km/h), so the cars do not drive as one.
const VS_SHIFT_KMH := {20: 160.0, 21: 170.0, 22: 180.0, 24: 175.0, 31: 170.0}
## The most frames a step may wait for what it expects.
const VS_STEP_FRAMES := 900
## Steps of a round before the tool empties P1's tank (rounds after the first).
const VS_ROUND_STEPS := 240
## The default cap on the scenario's frames (--frames).
const VS_FRAMES := 9000

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

# Scenario versus: what was seen (_vs_report() prints it), and where the script is.
var vs_seen := {}
var vs_rounds_ended := 0
var _vs_step := 0
var _vs_since := 0
var _vs_mark := {}
var _vs_stuck := false


func _initialize() -> void:
	if not begin():
		finish(1)
		return
	scenario = user_arg("scenario", scenario)
	if scenario == "versus":
		frames = user_arg("frames", str(VS_FRAMES)).to_int()
		start_app(SEED)
		_phaser_speed_rules()
		return
	frames = user_arg("frames", str(frames)).to_int()
	if scenario != "1p":
		printerr("smoke: unknown scenario %s (1p or versus)" % scenario)
		finish(1)
		return
	start_app(SEED)
	_start_sequence(START)
	_start_sequence(ESC_PAUSE, PAUSE_AT)
	_start_sequence(FOCUS, FOCUS_OUT_AT)


func _process(_delta: float) -> bool:
	frame += 1
	if scenario == "versus":
		_vs_frame()
		return false
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
			# The single-player game is no longer on the title (LOCAL opens the join screen): start it as the app would.
			app.start_game()
		"check game":
			reached_game = game() != null
			if not reached_game:
				_fail("the single-player game did not start")
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
			# The keyboard's long nitro has emptied the tank: a full one for the pad's A to burn.
			if w != null:
				w.player().nitro_tank = 1.0
			pad_button(PAD, JOY_BUTTON_A, true)
		"check A held":
			var both := Held.ACCEL | Held.NITRO
			held_by_a = (
				app.input.pads.devices.has(PAD) and Keyboard.held() == 0 and (app.input.held() & both) == both
				and w != null and w.player().gear == Car.GEAR_NITRO
			)
			if not held_by_a:
				_fail("the pad's A did not give nitro and throttle (frame %d)" % frame)
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
			# The keyboard's long nitro has emptied the tank: a full one for the pad's A to burn.
			if w != null:
				w.player().nitro_tank = 1.0
			pad_button(PAD, JOY_BUTTON_A, true)
		"start from title":
			app.start_game()
		"check title":
			title_by_start = on_title()
			if not title_by_start:
				_fail("Start at a game over did not go to the title (frame %d)" % frame)
		"check game from title":
			game_by_a = _expect_new_game(false, "starting from the title")
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
		_fail("the joypad did not take over (the keys up, then A for nitro and throttle)")
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
	if not ok:
		print("smoke: FAIL")
	# "smoke: PASS" comes from _finalize() at the very end, and only if no error was logged until then.
	finish(0 if ok else 1, "smoke: PASS")


# --- Scenario versus (B2) ----------------------------------------------------------------------------------------------


## The versus scenario's steps, in order: each is a method that takes the frames since the step began and returns
## true once it is done (see the comment at the top).
static func vs_steps() -> Array[String]:
	return [
		"_vs_title", "_vs_join", "_vs_bots", "_vs_leave", "_vs_start", "_vs_pause", "_vs_focus", "_vs_unplug",
		"_vs_replug", "_vs_claim", "_vs_round_over", "_vs_match_over", "_vs_rematch", "_vs_to_title",
	]


func _vs_frame() -> void:
	if frame == 1:
		# The app booted on the tree's first frame (its _ready()); its seats exist from here on.
		app.seats.guid_of = func(device: int) -> String: return VS_GUIDS.get(device, "")
	var steps := vs_steps()
	if _vs_step < steps.size() and not _vs_stuck:
		_vs_drive()
		var waited := frame - _vs_since
		if call(steps[_vs_step], waited):
			_vs_step += 1
			_vs_since = frame
			_vs_mark = {}
		elif waited > VS_STEP_FRAMES:
			_fail("versus: step %s did not finish within %d frames" % [steps[_vs_step], VS_STEP_FRAMES])
			_vs_stuck = true
	if _vs_step >= steps.size() or _vs_stuck or frame >= frames:
		_vs_report()


## While a race is on, every seated pad drives its car.
func _vs_drive() -> void:
	if versus() == null:
		return
	for device: int in VS_SHIFT_KMH:
		if app.seats.seat_of(device) >= 0:
			pad_autopilot(device, VS_SHIFT_KMH[device])


## Records what a step saw; a check that fails is a failure of the run.
func _vs_check(name: String, ok: bool, what: String) -> bool:
	vs_seen[name] = ok
	if not ok:
		_fail("versus: %s (frame %d)" % [what, frame])
	return ok


func _vs_match() -> Match:
	var screen := versus()
	return screen.game_match if screen != null else null


func _vs_world() -> World:
	var m := _vs_match()
	return m.world if m != null else null


func _vs_title(waited: int) -> bool:
	if waited == 20:
		_vs_check("title", on_title(), "the title did not open")
	elif waited == 24:
		tap(KEY_ENTER)
	elif waited > 24 and join_screen() != null:
		return _vs_check("join screen", app.input == app.seats, "the join screen did not take the seats' input")
	return false


func _vs_join(waited: int) -> bool:
	for i in VS_PADS.size():
		if waited == 1 + 3 * i:
			pad_tap(VS_PADS[i], JOY_BUTTON_A)
	if waited == 12:
		var seated := [app.seats.seat_of(VS_PADS[0]), app.seats.seat_of(VS_PADS[1]), app.seats.seat_of(VS_PADS[2])]
		return _vs_check("joined", seated == [0, 1, 2] and app.seats.bots == 3, "three pads did not take seats 0 to 2: %s" % [seated])
	return false


func _vs_bots(waited: int) -> bool:
	var p1 := VS_PADS[0]
	if waited == 1:
		_vs_mark["before"] = app.seats.bots
		pad_tap(p1, JOY_BUTTON_DPAD_RIGHT)
		pad_tap(p1, JOY_BUTTON_DPAD_LEFT)
	elif waited == 5:
		var counts := [_vs_mark["before"], app.seats.bots]
		return _vs_check("bots", counts == [3, 3], "the bots did not fill the 3 empty seats by themselves: %s" % [counts])
	return false


func _vs_leave(waited: int) -> bool:
	if waited == 1:
		pad_tap(VS_LEAVER, JOY_BUTTON_A)
	elif waited == 3:
		_vs_mark["joined"] = app.seats.seat_of(VS_LEAVER)
		pad_tap(VS_LEAVER, JOY_BUTTON_B)
	elif waited == 5:
		var ok: bool = _vs_mark["joined"] == 3 and app.seats.seat_of(VS_LEAVER) == -1 and app.seats.bots == 3
		return _vs_check("leave", ok and app.seats.kind_of(3) == Seats.BOT, "a fourth pad did not join and leave with B")
	return false


func _vs_start(waited: int) -> bool:
	if waited == 1:
		pad_tap(VS_PADS[1], JOY_BUTTON_START)
	elif waited == 3:
		var lineup: Array = app.seats.lineup
		var ok := versus() != null and lineup == [0, 1, 2, 3, 4, 5] and app.seats.humans_mask() == 0b000111
		return _vs_check("race", ok, "Start did not begin a race of three pads and three bots")
	return false


func _vs_pause(waited: int) -> bool:
	var w := _vs_world()
	if waited == 240:
		pad_tap(VS_PADS[0], JOY_BUTTON_START)
	elif waited == 243:
		_vs_check("paused by Start", w.phase == World.PAUSED, "Start on P1's pad did not pause")
		_vs_mark["ys"] = _vs_positions(w)
	elif waited == 273:
		_vs_check("still while paused", w.phase == World.PAUSED and _vs_positions(w) == _vs_mark["ys"], "a car moved while paused")
		pad_tap(VS_PADS[2], JOY_BUTTON_START)
	elif waited == 276:
		return _vs_check("resumed by Start", w.phase == World.RUNNING, "another person's Start did not resume")
	return false


func _vs_focus(waited: int) -> bool:
	var w := _vs_world()
	if waited == 60:
		notification(NOTIFICATION_APPLICATION_FOCUS_OUT)
	elif waited == 63:
		_vs_check("focus pause", w.phase == World.PAUSED, "losing focus did not pause the round")
		notification(NOTIFICATION_APPLICATION_FOCUS_IN)
	elif waited == 73:
		_vs_check("stays paused", w.phase == World.PAUSED, "getting focus back resumed the round by itself")
		pad_tap(VS_PADS[1], JOY_BUTTON_START)
	elif waited == 76:
		return _vs_check("resumed after focus", w.phase == World.RUNNING, "Start did not resume after the focus pause")
	return false


func _vs_unplug(waited: int) -> bool:
	var w := _vs_world()
	if waited == 30:
		Input.joy_connection_changed.emit(VS_PADS[1], false)
		_vs_mark["y"] = w.players[1].y_world
	elif waited == 31:
		var screen := versus()
		var info := VersusHud.seat_info(screen.game_match, screen.lineup, screen.pads_here(), 1)
		_vs_check("orphaned", app.seats.is_orphan(1) and app.seats.seat_byte(1) == PlayerInput.BOT and info["no_pad"],
			"P2's seat was not orphaned (0xFF, NO PAD) when its pad went away")
	elif waited == 91:
		var ok := w.phase == World.RUNNING and _vs_match().phase == Match.PLAYING and w.players[1].y_world > float(_vs_mark["y"]) + 100.0
		return _vs_check("bot drives", ok, "the round stopped, or nothing drove P2's car, after its pad went away")
	return false


func _vs_replug(waited: int) -> bool:
	if waited == 30:
		Input.joy_connection_changed.emit(VS_P2_AGAIN, true)
	elif waited == 31:
		var ok := app.seats.seat_of(VS_P2_AGAIN) == 1 and not app.seats.is_orphan(1)
		return _vs_check("same GUID back", ok, "P2's pad, back under another number, did not take its seat back")
	return false


func _vs_claim(waited: int) -> bool:
	if waited == 30:
		Input.joy_connection_changed.emit(VS_PADS[2], false)
		Input.joy_connection_changed.emit(VS_NEWCOMER, true)
	elif waited == 31:
		_vs_check("connecting takes nothing", app.seats.is_orphan(2) and app.seats.seat_of(VS_NEWCOMER) == -1,
			"a pad of another GUID took the orphan seat by connecting")
		pad_tap(VS_NEWCOMER, JOY_BUTTON_A)
	elif waited == 33:
		return _vs_check("claimed with A", app.seats.seat_of(VS_NEWCOMER) == 2 and not app.seats.is_orphan(2),
			"A on a new pad did not take the orphan seat")
	return false


## Round 1 ends with P1's tank emptied; A before MATCH_CONFIRM_TICKS steps does nothing, A after it starts round 2.
func _vs_round_over(waited: int) -> bool:
	var m := _vs_match()
	if waited == 30:
		m.world.players[0].fuel = 0.01
	elif waited == 32:
		vs_rounds_ended = m.rounds_played()
		_vs_check("round over", m.phase == Match.ROUND_OVER and m.round_number == 1, "emptying P1's tank did not end round 1")
	elif waited == 62:
		pad_press_a(VS_P2_AGAIN)
	elif waited == 64:
		_vs_check("early A ignored", m.phase == Match.ROUND_OVER, "A on the round's panel counted before the delay")
	elif waited == 32 + Config.MATCH_CONFIRM_TICKS + 4:
		pad_press_a(VS_P2_AGAIN)
	elif waited == 32 + Config.MATCH_CONFIRM_TICKS + 6:
		var ok := m.phase == Match.PLAYING and m.round_number == 2 and m.world.phase == World.RUNNING
		return _vs_check("next round", ok, "A after the delay did not start round 2")
	return false


## Later rounds run VS_ROUND_STEPS steps, then P1's tank is emptied; P2 confirms each; until the match is decided.
func _vs_match_over(_waited: int) -> bool:
	var m := _vs_match()
	if m.phase == Match.PLAYING and m.world.phase == World.RUNNING and m.world.stage_ticks == VS_ROUND_STEPS:
		m.world.players[0].fuel = 0.01
	elif m.phase == Match.ROUND_OVER and m.phase_ticks == Config.MATCH_CONFIRM_TICKS + 2:
		pad_press_a(VS_P2_AGAIN)
	elif m.phase == Match.MATCH_OVER:
		vs_rounds_ended = m.rounds_played()
		return _vs_check("match over", m.rounds_played() >= 2, "the match ended after fewer than two rounds")
	return false


## At the match's end, A (from MATCH_CONFIRM_TICKS steps on) plays a rematch on the same seats with the next seed.
func _vs_rematch(_waited: int) -> bool:
	var m := _vs_match()
	if not _vs_mark.has("match"):
		_vs_mark["match"] = m
		_vs_mark["seed"] = m.world.game_seed
	var first: Match = _vs_mark["match"]
	if m == first and m.phase_ticks == Config.MATCH_CONFIRM_TICKS + 2:
		pad_press_a(VS_NEWCOMER)
	elif m != first:
		var lineup: Array = versus().lineup
		var ok := m.world.game_seed == int(_vs_mark["seed"]) + 1 and lineup == [0, 1, 2, 3, 4, 5]
		return _vs_check("rematch", ok and m.phase == Match.PLAYING, "A at the match's end did not play a rematch on the same seats")
	return false


## In the rematch, Start pauses and Back goes to the title, where every pad leaves its seat.
func _vs_to_title(waited: int) -> bool:
	if waited == 60:
		pad_tap(VS_PADS[0], JOY_BUTTON_START)
	elif waited == 63:
		_vs_check("rematch paused", _vs_world().phase == World.PAUSED, "Start did not pause the rematch")
		pad_tap(VS_PADS[0], JOY_BUTTON_BACK)
	elif waited == 66:
		for device: int in VS_SHIFT_KMH:
			pad_let_go(device)
		return _vs_check("back to title", on_title() and app.seats.people() == 0 and app.input == app.solo, "Back while paused did not go to the title")
	return false


## Every live car's y_world, to see that nothing moves.
static func _vs_positions(w: World) -> Array[float]:
	var out: Array[float] = []
	for p: Car in w.players:
		out.append(p.y_world)
	return out


func _vs_report() -> void:
	var steps := vs_steps()
	if _vs_step < steps.size():
		_fail("versus: stopped at step %s after %d frames" % [steps[_vs_step], frame])
	app.seats.guid_of = Seats.engine_guid
	var names: Array[String] = []
	for name: String in vs_seen:
		if vs_seen[name]:
			names.append(name)
	var logged := errors()
	print("smoke versus: %s" % ", ".join(names))
	print("smoke versus: %d frames, %d of %d steps, rounds in the first match %d, errors %d" % [
		frame, _vs_step, steps.size(), vs_rounds_ended, logged.size()
	])
	var ok := _failures.is_empty() and logged.is_empty()
	if not ok:
		print("smoke: FAIL")
	finish(0 if ok else 1, "smoke: PASS")


## The versus scenario was written for Phaser's speed rules (low gear 198 km/h, slow nitro, no tank): its autopilot
## pads and its timed fuel cuts keep the cars alive for that long. The game's own rules (Config.game()) are played by
## the 1p scenario and the tests.
func _phaser_speed_rules() -> void:
	for pair: Array in [
		["low_gear_top", 198.0], ["low_gear_accel", 70.0], ["nitro_accel", 45.0], ["nitro_slow_accel", 15.0],
		["nitro_slow_below", 160.0], ["nitro_tank_seconds", 0.0], ["race_finish_px", 0.0],
	]:
		app.tuning.set_value(pair[0], pair[1])
