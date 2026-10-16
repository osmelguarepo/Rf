extends Node
## The application: the root of the main scene, scenes/boot.tscn (docs/GODOT_PLAN.md §2-3, §5). It outlives the
## screens and owns what they share:
##
## - Boot: the atlas, frames and font (scripts/view/atlas.gd) and the input map (scripts/input/keyboard.gd).
## - Input: every input event goes to `input` (scripts/input/local_input.gd), which latches presses until a step or a
##   menu takes them.
## - The fixed step: each frame `clock` (fixed_step.gd) turns the frame's length into 0 to 5 steps of 1/60 s, and
##   the current screen runs them (frame()).
## - Focus: when the application loses focus (NOTIFICATION_APPLICATION_FOCUS_OUT, or PAUSED on mobile) the current
##   screen hears on_focus_lost(); the game screen pauses a running game.
## - Screens: show_title() and start_game() swap the current screen, a child of this node. A screen is a scene whose
##   root script has setup(app), called before it enters the tree (it builds everything there, not in _ready()),
##   frame(steps, delta) and on_focus_lost().
## - The session: the best score and the seeds of new games.
## - --selftest (after the "--" of the command line): boots, drives SELFTEST_TICKS steps through the real screens and
##   checks the result, then draws SELFTEST_FRAMES frames of a driven game, and quits with 0 (pass) or 1 (fail, or an
##   error logged on the way). Its first game's seed is SELFTEST_SEED. --seed=N fixes the first game's seed.

const Atlas := preload("res://scripts/view/atlas.gd")
const LocalInput := preload("res://scripts/input/local_input.gd")
const Keyboard := preload("res://scripts/input/keyboard.gd")
const FixedStep := preload("res://scripts/app/fixed_step.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")
const World := preload("res://scripts/sim/world.gd")

const TITLE_SCENE := "res://scenes/title.tscn"
const GAME_SCENE := "res://scenes/game.tscn"
const SELFTEST_TICKS := 600
const SELFTEST_FRAMES := 120
const SELFTEST_SEED := 1


## Collects the errors logged while the self test runs (warnings do not count), as tests/run_tests.gd does.
class ErrorLog extends Logger:
	var _mutex := Mutex.new()
	var _errors := PackedStringArray()

	func _log_error(
		function: String,
		file: String,
		line: int,
		code: String,
		rationale: String,
		_editor_notify: bool,
		error_type: int,
		_script_backtraces: Array[ScriptBacktrace]
	) -> void:
		if error_type == ERROR_TYPE_WARNING:
			return
		_mutex.lock()
		_errors.append("%s:%d (%s): %s" % [file, line, function, rationale if not rationale.is_empty() else code])
		_mutex.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass

	func errors() -> PackedStringArray:
		_mutex.lock()
		var out := _errors.duplicate()
		_mutex.unlock()
		return out


var atlas: Atlas
var input: LocalInput
var clock := FixedStep.new()
## Best score this session. A new game starts with it as its high score.
var high_score: int = 0
## The first game's seed when >= 0 (--seed=N, or set by a tool before the node enters the tree); random otherwise.
## Each later game uses the previous seed + 1.
var seed_override: int = -1
## True when the atlas, every frame and the font loaded.
var booted: bool = false
var _screen: Node = null
var _last_seed: int = -1
var _started := false
## The self test's frames drawn so far, or -1 when no self test runs; its error log and problems.
var _selftest_frame := -1
var _selftest_log: ErrorLog = null
var _selftest_problems := PackedStringArray()


func _ready() -> void:
	start()


## Boots and opens the title, or runs the self test and quits. _ready() calls it. Code that adds the app to a tree
## that is not running yet (tests/run_tests.gd runs every test inside its _initialize(), before the root enters the
## tree, so no _ready() arrives) calls it directly. A second call does nothing.
func start() -> void:
	if _started:
		return
	_started = true
	var selftest := _read_arguments()
	boot()
	if not Input.joy_connection_changed.is_connected(_on_joy_connection_changed):
		Input.joy_connection_changed.connect(_on_joy_connection_changed)
	if selftest:
		_begin_selftest()
		return
	show_title()


## Reads the arguments after "--". Returns true if --selftest is among them.
func _read_arguments() -> bool:
	var selftest := false
	for argument: String in OS.get_cmdline_user_args():
		if argument == "--selftest":
			selftest = true
		elif argument.begins_with("--seed=") and argument.trim_prefix("--seed=").is_valid_int():
			seed_override = argument.trim_prefix("--seed=").to_int()
	return selftest


## Loads the art and the font and builds the input map. Returns `booted`.
func boot() -> bool:
	Keyboard.build_input_map()
	input = LocalInput.new()
	atlas = Atlas.new()
	booted = atlas.load_all()
	return booted


## The seed for a new game.
func next_seed() -> int:
	if _last_seed >= 0:
		_last_seed = (_last_seed + 1) & 0xFFFFFFFF
	elif seed_override >= 0:
		_last_seed = seed_override & 0xFFFFFFFF
	else:
		_last_seed = randi()
	return _last_seed


func current_screen() -> Node:
	return _screen


func show_title() -> Node:
	return _switch_to(TITLE_SCENE)


func start_game() -> Node:
	return _switch_to(GAME_SCENE)


## Replaces the current screen with a new instance of a scene. Presses and leftover step time do not carry over.
func _switch_to(path: String) -> Node:
	if _screen != null:
		remove_child(_screen)
		_screen.queue_free()
		_screen = null
	input.clear_presses()
	clock.reset()
	var scene := load(path) as PackedScene
	_screen = scene.instantiate()
	_screen.setup(self)
	add_child(_screen)
	return _screen


func _input(event: InputEvent) -> void:
	if input != null:
		input.handle_event(event)


func _process(delta: float) -> void:
	if _selftest_frame >= 0:
		_selftest_draw_frame()
		return
	if _screen == null:
		return
	_screen.frame(clock.advance(delta), delta)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_APPLICATION_PAUSED:
		if _screen != null:
			_screen.on_focus_lost()


func _on_joy_connection_changed(device: int, connected: bool) -> void:
	if input != null:
		input.pads.connection_changed(device, connected)


# --- Self test -------------------------------------------------------------------------------------------------------


## Starts the self test: the checks of selftest_problems() now, then SELFTEST_FRAMES frames of a game drawn by the
## engine (_selftest_draw_frame()), so drawing code runs too. Errors logged on the way fail it.
func _begin_selftest() -> void:
	if seed_override < 0:
		seed_override = SELFTEST_SEED
	_selftest_log = ErrorLog.new()
	OS.add_logger(_selftest_log)
	_selftest_problems = selftest_problems()
	start_game()
	_selftest_frame = 0


## One frame of the self test's drawn game: a step with the scripted input, then the view. Ends the test at the end.
func _selftest_draw_frame() -> void:
	if _selftest_frame >= SELFTEST_FRAMES:
		return
	_screen.step_once(PackedByteArray([selftest_byte(_selftest_frame)]))
	_screen.render()
	_selftest_frame += 1
	if _selftest_frame == SELFTEST_FRAMES:
		get_tree().quit(_end_selftest())


## Prints the result of the self test and returns its exit code: 0 if it passed, 1 if not.
func _end_selftest() -> int:
	OS.remove_logger(_selftest_log)
	var problems := _selftest_problems.duplicate()
	problems.append_array(_selftest_log.errors())
	for problem: String in problems:
		printerr("selftest: FAIL ", problem)
	if not problems.is_empty():
		return 1
	print("selftest: ok (%d ticks checked, %d frames drawn)" % [SELFTEST_TICKS, SELFTEST_FRAMES])
	return 0


## The scripted input of the self test at a tick: high gear and throttle, steering left, none, right, none, each for
## two seconds, and a pause press at two ticks.
static func selftest_byte(tick: int) -> int:
	var steer: int = [-1, 0, 1, 0][floori(tick / 120.0) % 4]
	var byte := PlayerInput.encode(true, false, steer, true)
	if tick == 300 or tick == 310:
		byte |= PlayerInput.PAUSE
	return byte


## Boots through the title into a game, drives it, and returns what went wrong ([] if nothing).
func selftest_problems() -> PackedStringArray:
	var problems := PackedStringArray()
	if not booted:
		problems.append("boot: the atlas, a frame or the font did not load")
	var title := show_title()
	if title == null or title.name != "Title":
		problems.append("the title screen did not open")
	var game := start_game()
	if game == null or game.name != "Game":
		problems.append("the game screen did not open")
		return problems
	var world: World = game.world
	var seed_value := world.game_seed
	var start_high := world.high_score
	var bytes: Array[int] = []
	var paused := false
	for tick in SELFTEST_TICKS:
		if world.phase == World.GAME_OVER:
			break
		var byte := selftest_byte(tick)
		bytes.append(byte)
		game.step_once(PackedByteArray([byte]))
		paused = paused or world.phase == World.PAUSED
		if tick % 60 == 0:
			game.render()
	if not paused:
		problems.append("the pause press did not pause the game")
	if world.tick != bytes.size() or bytes.size() < 200:
		problems.append("ran %d ticks of %d" % [world.tick, bytes.size()])
	if world.player().y_world <= 0.0 and world.stage == 1:
		problems.append("the car did not move")
	# Determinism: the same seed and bytes, without the view, give the same world.
	var replay := World.new(world.cfg, seed_value, 1, start_high)
	for byte: int in bytes:
		replay.step(PackedByteArray([byte]))
	if replay.checksum() != world.checksum():
		problems.append("a replay of the same inputs differs")
	if show_title() == null:
		problems.append("could not go back to the title")
	return problems
