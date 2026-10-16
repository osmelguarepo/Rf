extends "res://tools/tool_base.gd"
## The smoke test (docs/GODOT_PLAN.md §6): plays the real game, from its main scene, with real key events on a fixed
## timeline, and checks what happened. Headless, no renderer needed:
##
##   timeout 300 godot --headless --fixed-fps 60 --path . -s res://tools/smoke.gd -- --scenario=1p --frames=10800
##
## The project must have been imported (tools/test.sh does it; or godot --headless --path . --import).
##
## Scenario 1p, frame by frame (--fixed-fps 60 makes every frame exactly one simulation step):
##   30          Enter on the title: the game starts.
##   40          X goes down and stays down: high gear and throttle for the whole run.
##   every 120   the steering changes: left, none, right, none, ... (real key presses and releases).
##   600, 660    Esc: pause, then resume.
##   900         the application loses focus (NOTIFICATION_APPLICATION_FOCUS_OUT): the game must pause.
##   +13         focus comes back (NOTIFICATION_APPLICATION_FOCUS_IN): the game must stay paused.
##   +76         Esc resumes, and X and the steering key go down again: losing focus let go of every key.
##   game over   one second later, Enter: a new game (retry). The same after a stage clear, to go on.
## A press planned for a running game waits for the next frame where the game is running.
##
## It passes (exit 0) when the game screen was reached, Esc paused and resumed, at least one game ended and was
## retried, losing focus paused, and no error was logged (the filter of tools/test.sh: no ERROR or SCRIPT ERROR).
## Phase B adds scenarios (B3).

const SEED := 1
const ENTER_AT := 30
const X_AT := 40
const STEER_EVERY := 120
const STEER_CYCLE: Array[Key] = [KEY_LEFT, KEY_NONE, KEY_RIGHT, KEY_NONE]
const PAUSE_AT := 600
const RESUME_AT := 660
const FOCUS_OUT_AT := 900
const FOCUS_IN_DELAY := 10
const FOCUS_RESUME_DELAY := 60
## Frames to wait at a game over or a stage clear before pressing Enter.
const PANEL_WAIT := 60
## Frames after a key event before its effect is checked.
const SETTLE := 3
const PROGRESS_EVERY := 1800

var frames: int = 10800
var scenario: String = "1p"

var reached_game := false
var paused_by_esc := false
var resumed_by_esc := false
var paused_by_focus := false
var stayed_paused_on_focus_in := false
var resumed_after_focus := false
var game_overs := 0
var retries := 0
var stage_clears := 0
var _failures: Array[String] = []
## Planned actions: frame -> what. Moved to a later frame while the game is not running.
var _plan := {}
var _panel_since := -1
var _world_seen: World = null


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
	_plan = {
		PAUSE_AT: "pause", PAUSE_AT + SETTLE: "check paused",
		RESUME_AT: "resume", RESUME_AT + SETTLE: "check resumed",
		FOCUS_OUT_AT: "focus out",
	}


func _process(_delta: float) -> bool:
	frame += 1
	_run_planned()
	if frame == ENTER_AT:
		if not on_title():
			_fail("the title screen was not showing at frame %d" % frame)
		tap(KEY_ENTER)
	if frame == ENTER_AT + SETTLE:
		reached_game = game() != null
		if not reached_game:
			_fail("Enter on the title did not start a game")
	if frame == X_AT:
		key(KEY_X, true)
	if frame >= STEER_EVERY and frame % STEER_EVERY == 0:
		hold_steer(STEER_CYCLE[floori(frame / float(STEER_EVERY)) % STEER_CYCLE.size()])
	_watch_game()
	if frame % PROGRESS_EVERY == 0:
		_progress()
	if frame >= frames:
		_report()
	return false


## Planned actions for this frame. Those meant for a running game wait while it is not running.
func _run_planned() -> void:
	if not _plan.has(frame):
		return
	var what: String = _plan[frame]
	_plan.erase(frame)
	var w := world()
	var running := w != null and w.phase == World.RUNNING
	match what:
		"pause":
			if not running:
				_postpone(what)
				return
			tap(KEY_ESCAPE)
			_plan[frame + SETTLE] = "check paused"
			_drop_planned("check paused", frame + SETTLE)
		"check paused":
			paused_by_esc = w != null and w.phase == World.PAUSED
			if not paused_by_esc:
				_fail("Esc did not pause (frame %d)" % frame)
		"resume":
			tap(KEY_ESCAPE)
		"check resumed":
			resumed_by_esc = w != null and w.phase == World.RUNNING
			if not resumed_by_esc:
				_fail("Esc did not resume (frame %d)" % frame)
		"focus out":
			if not running:
				_postpone(what)
				return
			notification(NOTIFICATION_APPLICATION_FOCUS_OUT)
			_plan[frame + SETTLE] = "check focus pause"
		"check focus pause":
			paused_by_focus = w != null and w.phase == World.PAUSED
			if not paused_by_focus:
				_fail("losing focus did not pause (frame %d)" % frame)
			_plan[frame + FOCUS_IN_DELAY] = "focus in"
		"focus in":
			notification(NOTIFICATION_APPLICATION_FOCUS_IN)
			_plan[frame + SETTLE] = "check still paused"
		"check still paused":
			stayed_paused_on_focus_in = w != null and w.phase == World.PAUSED
			if not stayed_paused_on_focus_in:
				_fail("getting focus back resumed the game by itself (frame %d)" % frame)
			_plan[frame + FOCUS_RESUME_DELAY] = "resume after focus"
		"resume after focus":
			# Losing focus let go of every key (Godot releases held keys then, as the Phaser version did on blur),
			# so the player presses Esc to resume and holds X and the steering key again.
			tap(KEY_ESCAPE)
			key(KEY_X, true)
			if _steer_key != KEY_NONE:
				key(_steer_key, true)
			_plan[frame + SETTLE] = "check resumed after focus"
		"check resumed after focus":
			resumed_after_focus = w != null and w.phase == World.RUNNING
			if not resumed_after_focus:
				_fail("Esc did not resume after the focus pause (frame %d)" % frame)


## Moves an action to the next frame, and the checks planned after it along with it.
func _postpone(what: String) -> void:
	_plan[frame + 1] = what
	if what == "pause":
		_drop_planned("check paused", -1)
		var at := _frame_of("resume")
		if at >= 0:
			_plan.erase(at)
			_drop_planned("check resumed", -1)
			_plan[frame + 1 + (RESUME_AT - PAUSE_AT)] = "resume"
			_plan[frame + 1 + (RESUME_AT - PAUSE_AT) + SETTLE] = "check resumed"


func _frame_of(what: String) -> int:
	for at: int in _plan:
		if _plan[at] == what:
			return at
	return -1


## Removes a planned action, except the one at `keep`.
func _drop_planned(what: String, keep: int) -> void:
	for at: int in _plan.keys():
		if _plan[at] == what and at != keep:
			_plan.erase(at)


## Game overs and stage clears: count them, wait a second, press Enter, and check that a new game (or the next stage)
## started.
func _watch_game() -> void:
	var w := world()
	if w == null:
		_panel_since = -1
		return
	if w != _world_seen:
		# A new world after one that ended is a retry.
		if _world_seen != null and _world_seen.phase == World.GAME_OVER:
			retries += 1
		_world_seen = w
	var on_panel := w.phase == World.GAME_OVER or w.phase == World.STAGE_CLEAR
	if not on_panel:
		_panel_since = -1
		return
	if _panel_since < 0:
		_panel_since = frame
		if w.phase == World.GAME_OVER:
			game_overs += 1
		else:
			stage_clears += 1
	if frame - _panel_since == PANEL_WAIT:
		tap(KEY_ENTER)


func _progress() -> void:
	var w := world()
	if w == null:
		print("smoke: frame %d, no game" % frame)
		return
	var p := w.player()
	print("smoke: frame %d, %s, stage %d, tick %d, %d km/h, score %d, fuel %.1f, game overs %d, retries %d" % [
		frame, World.PHASE_NAMES[w.phase], w.stage, w.tick, roundi(p.speed), p.score, p.fuel, game_overs, retries
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
	if game_overs < 1 or retries < 1:
		_fail("no game over followed by a retry (game overs %d, retries %d)" % [game_overs, retries])
	var logged := errors()
	print("smoke %s: %d frames, game overs %d, retries %d, stage clears %d, Esc pause/resume %s/%s, focus pause %s, errors %d" % [
		scenario, frame, game_overs, retries, stage_clears, paused_by_esc, resumed_by_esc, paused_by_focus, logged.size()
	])
	var ok := _failures.is_empty() and logged.is_empty()
	print("smoke: %s" % ("PASS" if ok else "FAIL"))
	finish(0 if ok else 1)
