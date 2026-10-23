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
## - The window: project.godot opens it at 1920x1080 (3x the 640x360 picture); fit_window() shrinks it on a smaller
##   screen to the largest whole multiple of the picture that fits.
## - Screens: show_title() and start_game() swap the current screen, a child of this node. A screen is a scene whose
##   root script has setup(app), called before it enters the tree (it builds everything there, not in _ready()),
##   frame(steps, delta) and on_focus_lost().
## - The session: the best score and the seeds of new games.
## - Versus (B2): the title's VERSUS choice opens the join screen (show_join()), whose Start opens a versus race
##   (start_versus()). The active input is then `seats` (scripts/input/seats.gd: one byte per seat from each seat's
##   joypad) instead of `solo` (the keyboard and every pad as one player); going back to the title lets every pad go.
##   Menu commands (up, down, accept, back...) of every device go to `nav` (scripts/input/nav.gd) for the menus.
## - F11 and Alt+Enter, on every screen, switch between a window and fullscreen (toggle_fullscreen()); the picture
##   keeps its whole-number scale (project.godot's stretch settings). The key never reaches the screens.
## - Steam Input (B4, scripts/input/steam_input.gd): when GodotSteam is loaded and Steam runs, `steam` turns Steam's
##   controllers into virtual pads, read once a frame (poll_steam()) and parsed into Input like a pad driver's events,
##   so every screen reads them as pads. Once Steam has a controller, Godot's own pads are left out for the session.
##   Steam starts in _ready() (start_steam()), so only the game itself talks to Steam: tests boot apps with start(),
##   and the tools (tools/tool_base.gd) set no_steam.
## - --selftest (after the "--" of the command line): boots, drives SELFTEST_TICKS steps through the real screens and
##   checks the result (selftest_problems(): among others, a pause press pauses the game and a second one resumes
##   it), then a versus race of SELFTEST_TICKS steps through the join and race screens (selftest_versus_problems(),
##   B2), then draws SELFTEST_FRAMES frames of a driven game, SELFTEST_JOIN_FRAMES of the join screen and
##   SELFTEST_VERSUS_FRAMES of a versus race, and quits with 0 (pass) or 1 (fail, or an error logged on the way). Its
##   first game's seed is SELFTEST_SEED. --seed=N fixes the first game's seed.

const Atlas := preload("res://scripts/view/atlas.gd")
const PlayerColours := preload("res://scripts/view/player_colours.gd")
const LocalInput := preload("res://scripts/input/local_input.gd")
const Seats := preload("res://scripts/input/seats.gd")
const Nav := preload("res://scripts/input/nav.gd")
const Keyboard := preload("res://scripts/input/keyboard.gd")
const SteamInput := preload("res://scripts/input/steam_input.gd")
const FixedStep := preload("res://scripts/app/fixed_step.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")
const World := preload("res://scripts/sim/world.gd")
const Match := preload("res://scripts/sim/match.gd")

const TITLE_SCENE := "res://scenes/title.tscn"
const GAME_SCENE := "res://scenes/game.tscn"
const JOIN_SCENE := "res://scenes/join.tscn"
const VERSUS_SCENE := "res://scenes/versus.tscn"
const SELFTEST_TICKS := 600
const SELFTEST_FRAMES := 120
## Frames of the join screen and of a versus race the self test draws after the game's (B2).
const SELFTEST_JOIN_FRAMES := 30
const SELFTEST_VERSUS_FRAMES := 60
const SELFTEST_SEED := 1
## The ticks of the self test's two pause presses: the first pauses the game, the second resumes it.
const SELFTEST_PAUSE_TICK := 300
const SELFTEST_RESUME_TICK := 310
## The versus leg (B2): two synthetic pads (devices no real pad uses), and the tick at which the second goes away.
const SELFTEST_PADS: Array[int] = [90, 91]
const SELFTEST_DISCONNECT_TICK := 400


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
## The active input, which every input event goes to: `solo` or `seats`.
var input: LocalInput
## Single player and the title: the keyboard and every pad together.
var solo: LocalInput
## Versus: the join screen and the races. Its seats last until the app goes back to the title.
var seats: Seats
## Menu commands from every device, for the menus (title, join screen, versus pause and results).
var nav := Nav.new()
## Steam's controllers as pads (B4). Made by boot(), started by start_steam(); off until then.
var steam: SteamInput
## True keeps Steam Input off, as --no-steam does (set before the node enters the tree, as seed_override is). The tools
## set it (tools/tool_base.gd): they drive synthetic pads, which Steam would drop once it took over on a PC with Steam.
var no_steam: bool = false
## The title's last choice (title.gd CHOICE_LOCAL or CHOICE_ONLINE), shown again when it opens.
var title_choice: int = 0
## The window that F11 and Alt+Enter switch: the game's own when null. Tests give another, since a headless window
## never changes mode on a screen.
var fullscreen_window: Window = null
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
	start_steam()


## Boots and opens the title, or runs the self test and quits. _ready() calls it. Code that adds the app to a tree
## that is not running yet (tests/run_tests.gd runs every test inside its _initialize(), before the root enters the
## tree, so no _ready() arrives) calls it directly. A second call does nothing.
func start() -> void:
	if _started:
		return
	_started = true
	var selftest := _read_arguments()
	fit_window()
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


## Makes the window fit the screen it opens on. project.godot asks for 1920x1080; on a screen whose usable area is
## smaller, that window would hang off the edges, so it becomes the largest whole multiple of the 640x360 picture that
## fits (fitted_window_size(); 1280x720 on a 1366x768 or 1280x800 screen, or on a 1920x1080 one whose taskbar leaves
## 1040 rows), centred on the usable area. Nothing changes headless, when the window fits, when it is not a plain
## window (fullscreen, maximized), or when it does not have project.godot's size: then a size was asked for (Godot
## keeps --resolution to itself, so that is how it shows). Window decorations are not counted: their size is not known
## yet when the game starts.
func fit_window() -> void:
	if DisplayServer.get_name() == "headless" or not is_inside_tree():
		return
	var window := get_window()
	var project := Vector2i(
		ProjectSettings.get_setting("display/window/size/window_width_override"),
		ProjectSettings.get_setting("display/window/size/window_height_override")
	)
	if window.mode != Window.MODE_WINDOWED or window.size != project:
		return
	var usable := DisplayServer.screen_get_usable_rect(window.current_screen)
	var view := Vector2i(
		ProjectSettings.get_setting("display/window/size/viewport_width"),
		ProjectSettings.get_setting("display/window/size/viewport_height")
	)
	var fitted := fitted_window_size(window.size, usable.size, view)
	if fitted == window.size:
		return
	window.size = fitted
	window.position = usable.position + Vector2i(
		floori((usable.size.x - fitted.x) / 2.0), floori((usable.size.y - fitted.y) / 2.0)
	)


## The window size for a screen whose usable area is `usable`: `window` itself if it fits, or else the largest whole
## multiple of `view` that fits (at least 1x).
static func fitted_window_size(window: Vector2i, usable: Vector2i, view: Vector2i) -> Vector2i:
	if window.x <= usable.x and window.y <= usable.y:
		return window
	var multiple := maxi(1, mini(floori(usable.x / float(view.x)), floori(usable.y / float(view.y))))
	return view * multiple


## Loads the art and the font (and the six seats' recoloured cars) and builds the input map. Returns `booted`.
func boot() -> bool:
	Keyboard.build_input_map()
	solo = LocalInput.new()
	seats = Seats.new()
	seats.guid_of = guid_of
	use_steam(SteamInput.new())
	input = solo
	atlas = Atlas.new()
	booted = atlas.load_all()
	PlayerColours.add_frames(atlas)
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


## The title screen. Every pad leaves its versus seat.
func show_title() -> Node:
	if seats != null:
		seats.reset()
	input = solo
	return _switch_to(TITLE_SCENE)


## A single-player game.
func start_game() -> Node:
	input = solo
	return _switch_to(GAME_SCENE)


## The join screen (B2): the versus seats are open again; pads already on a seat stay there (back from a match).
func show_join() -> Node:
	seats.open()
	input = seats
	return _switch_to(JOIN_SCENE)


## A versus race of the join screen's seats: locks their line-up and opens the race screen. Returns null, and leaves
## the current screen alone, when the seats cannot make a match (World.versus_valid()).
func start_versus() -> Node:
	if not seats.lock():
		return null
	input = seats
	return _switch_to(VERSUS_SCENE)


## F11 and Alt+Enter: fullscreen, or back to a window (whose size and place the platform restores).
func toggle_fullscreen() -> void:
	var window := fullscreen_window
	if window == null and is_inside_tree():
		window = get_window()
	if window != null:
		window.mode = toggled_window_mode(window.mode)


## Fullscreen (either kind) goes to a window; any other mode to fullscreen.
static func toggled_window_mode(mode: Window.Mode) -> Window.Mode:
	if mode == Window.MODE_FULLSCREEN or mode == Window.MODE_EXCLUSIVE_FULLSCREEN:
		return Window.MODE_WINDOWED
	return Window.MODE_FULLSCREEN


## True for F11, or Enter (either) with Alt, going down. A key repeat is not one.
static func is_fullscreen_key(event: InputEvent) -> bool:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return false
	var code := key.physical_keycode if key.physical_keycode != KEY_NONE else key.keycode
	if code == KEY_F11:
		return true
	return key.alt_pressed and (code == KEY_ENTER or code == KEY_KP_ENTER)


## Replaces the current screen with a new instance of a scene. Presses, menu commands and leftover step time do not
## carry over.
func _switch_to(path: String) -> Node:
	if _screen != null:
		remove_child(_screen)
		_screen.queue_free()
		_screen = null
	input.clear_presses()
	nav.clear()
	clock.reset()
	var scene := load(path) as PackedScene
	_screen = scene.instantiate()
	_screen.setup(self)
	add_child(_screen)
	return _screen


func _input(event: InputEvent) -> void:
	if is_fullscreen_key(event):
		toggle_fullscreen()
		return
	if steam != null and steam.drops(event):
		return
	if input != null:
		input.handle_event(event)
	nav.handle_event(event)


func _process(delta: float) -> void:
	poll_steam()
	if _selftest_frame >= 0:
		_selftest_draw_frame()
		return
	if _screen == null:
		return
	_screen.frame(clock.advance(delta), delta)
	# Menu commands live for one frame: a screen takes them in frame(), and a screen without menus (the game) never
	# does, so they must not pile up there.
	nav.clear()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_APPLICATION_PAUSED:
		if _screen != null:
			_screen.on_focus_lost()


## Godot's pads coming and going (Input.joy_connection_changed), unless Steam is the session's source of pads (B4).
func _on_joy_connection_changed(device: int, connected: bool) -> void:
	if steam != null and steam.drops_device(device):
		return
	_pad_connection(device, connected)


## Both inputs follow the pads, whichever is active, and so do the menu commands.
func _pad_connection(device: int, connected: bool) -> void:
	for each: LocalInput in [solo, seats]:
		if each != null:
			each.connection_changed(device, connected)
	nav.connection_changed(device, connected)


# --- Steam Input (B4) ------------------------------------------------------------------------------------------------


## Gives the app its Steam Input adapter (boot() makes one; a test gives one with a fake singleton): its controllers'
## pad events and comings and goings reach the inputs as a pad's would.
func use_steam(adapter: SteamInput) -> void:
	steam = adapter
	adapter.pad_event.connect(_on_steam_pad_event)
	adapter.pad_connection.connect(_pad_connection)
	adapter.took_over.connect(_on_steam_took_over)


## Starts Steam Input once (_ready() calls it): nothing with --no-steam among `args` (the command line) or with
## no_steam, one warning without GodotSteam or without a Steam client (Godot's pads are read then). Returns the
## adapter's state.
func start_steam(args: PackedStringArray = SteamInput.command_line()) -> int:
	if steam == null:
		return SteamInput.OFF
	return steam.start_engine(PackedStringArray([SteamInput.NO_STEAM]) if no_steam else args)


## Reads Steam's controllers for this frame, before the screen runs: the racing action set while people drive, the
## menus set elsewhere.
func poll_steam() -> void:
	if steam != null:
		steam.frame(people_drive())


## True while people drive: a single-player game or a versus round that runs. Paused, between rounds, after a game or
## a match, and on the other screens, the menus set is read, so the panels answer a Steam controller as a pad: on the
## match-over panel B goes back to the join screen (in the racing set B accelerates).
func people_drive() -> bool:
	if _screen == null or not (_screen.name == &"Game" or _screen.name == &"Versus"):
		return false
	var world: World = _screen.world
	if world == null or world.phase != World.RUNNING:
		return false
	return _screen.name == &"Game" or (_screen.game_match as Match).phase == Match.PLAYING


## A pad's GUID for the seats: Steam's own for its controllers, the engine's for any other pad.
func guid_of(device: int) -> String:
	if steam != null and steam.owns(device):
		return steam.guid_of(device)
	return Seats.engine_guid(device)


## A button of a Steam controller's virtual pad going down or up, as a pad driver's event: into Input's state, then to
## _input(). The engine delivers it to _input() as it flushes; outside a running tree (the test runner) nothing would,
## so it goes there directly.
func _on_steam_pad_event(event: InputEvent) -> void:
	Input.parse_input_event(event)
	Input.flush_buffered_events()
	if not is_inside_tree():
		_input(event)


## Steam is the session's source of pads from now on: Godot's own pads leave the inputs (a seated one leaves its seat,
## or hands it to its bot in a race), since the same controllers now come through Steam.
func _on_steam_took_over() -> void:
	var known: Array[int] = []
	known.append_array(Input.get_connected_joypads())
	for each: LocalInput in [solo, seats]:
		if each != null:
			known.append_array(each.pads.devices)
	var gone: Array[int] = []
	for device: int in known:
		if not steam.owns(device) and not gone.has(device):
			gone.append(device)
	for device: int in gone:
		_pad_connection(device, false)


# --- Self test -------------------------------------------------------------------------------------------------------


## Starts the self test: the checks of selftest_problems() and selftest_versus_problems() now, then frames drawn by
## the engine (_selftest_draw_frame()): a game, the join screen and a versus race, so drawing code runs too. Errors
## logged on the way fail it.
func _begin_selftest() -> void:
	if seed_override < 0:
		seed_override = SELFTEST_SEED
	_selftest_log = ErrorLog.new()
	OS.add_logger(_selftest_log)
	_selftest_problems = selftest_problems()
	_selftest_problems.append_array(selftest_versus_problems())
	start_game()
	_selftest_frame = 0


## One frame of the self test's drawing: SELFTEST_FRAMES frames of the game (a step with the scripted input, then the
## view), then SELFTEST_JOIN_FRAMES of the join screen with the two pads of the versus leg on their seats and a bot,
## then SELFTEST_VERSUS_FRAMES of their race (a step with the seats' bytes, then the view). Ends the test at the end.
func _selftest_draw_frame() -> void:
	var join_from := SELFTEST_FRAMES
	var race_from := join_from + SELFTEST_JOIN_FRAMES
	var end := race_from + SELFTEST_VERSUS_FRAMES
	if _selftest_frame >= end:
		return
	if _selftest_frame < join_from:
		_screen.step_once(PackedByteArray([selftest_byte(_selftest_frame)]))
		_screen.render()
	elif _selftest_frame == join_from:
		show_join()
		for device: int in SELFTEST_PADS:
			seats.join(device)
		seats.set_bots(1)
	elif _selftest_frame < race_from:
		_screen.frame(0, FixedStep.STEP)
	else:
		if _selftest_frame == race_from and start_versus() == null:
			_selftest_problems.append("the versus race to draw did not open")
			_selftest_frame = end
			get_tree().quit(_end_selftest())
			return
		_screen.step_once(seats.step_bytes(seats.lineup.size()))
		_screen.render()
	_selftest_frame += 1
	if _selftest_frame == end:
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
	print("selftest: ok (%d ticks checked, %d versus ticks checked, %d frames drawn)" % [
		SELFTEST_TICKS, SELFTEST_TICKS, SELFTEST_FRAMES + SELFTEST_JOIN_FRAMES + SELFTEST_VERSUS_FRAMES
	])
	return 0


## The scripted input of the self test at a tick: high gear and throttle, steering left, none, right, none, each for
## two seconds, and a pause press at SELFTEST_PAUSE_TICK and at SELFTEST_RESUME_TICK.
static func selftest_byte(tick: int) -> int:
	var steer: int = [-1, 0, 1, 0][floori(tick / 120.0) % 4]
	var byte := PlayerInput.encode(true, false, steer, true)
	if tick == SELFTEST_PAUSE_TICK or tick == SELFTEST_RESUME_TICK:
		byte |= PlayerInput.PAUSE
	return byte


## Boots through the title into a game, drives it SELFTEST_TICKS steps with the bytes of `byte_at(tick)`
## (selftest_byte(), unless a test gives another script), and returns what went wrong ([] if nothing): the screens
## opened; the press at SELFTEST_PAUSE_TICK paused the game and nothing moved until the press at SELFTEST_RESUME_TICK
## resumed it, after which the car drove on; the steps all ran; and a replay of the same bytes gives the same world.
func selftest_problems(byte_at: Callable = selftest_byte) -> PackedStringArray:
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
	var still := true
	var resumed := false
	var y_resumed := 0.0
	for tick in SELFTEST_TICKS:
		if world.phase == World.GAME_OVER:
			break
		var byte: int = byte_at.call(tick)
		bytes.append(byte)
		var y_before := world.player().y_world
		game.step_once(PackedByteArray([byte]))
		if tick == SELFTEST_PAUSE_TICK:
			paused = world.phase == World.PAUSED
		elif tick > SELFTEST_PAUSE_TICK and tick < SELFTEST_RESUME_TICK:
			still = still and world.phase == World.PAUSED and world.player().y_world == y_before
		elif tick == SELFTEST_RESUME_TICK:
			resumed = world.phase == World.RUNNING
			y_resumed = world.player().y_world
		if tick % 60 == 0:
			game.render()
	if not paused:
		problems.append("the pause press at tick %d did not pause the game" % SELFTEST_PAUSE_TICK)
	elif not still:
		problems.append("the game did not stay paused, or the car moved, before tick %d" % SELFTEST_RESUME_TICK)
	elif not resumed:
		problems.append("the pause press at tick %d did not resume the game" % SELFTEST_RESUME_TICK)
	elif not (world.player().y_world > y_resumed):
		problems.append("the car did not drive on after the game resumed")
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


## The versus leg of the self test (B2): through the real join and race screens, two pads (SELFTEST_PADS: synthetic
## devices with nothing held, so their cars only get pushed along by the bottom edge) and one bot race SELFTEST_TICKS
## steps on a road kept empty (the rules are the simulation tests' business; here no seed can end the round early).
## It checks that the join screen and the race open, as a versus match of the two pads' seats and the bot's;
## that the program's pause press at SELFTEST_PAUSE_TICK pauses the round and nothing moves until the one at
## SELFTEST_RESUME_TICK resumes it; that the bot drives; that when the second pad goes away (SELFTEST_DISCONNECT_TICK)
## its seat's byte is 0xFF from then on and the round goes on; that a replay of the same bytes gives the same match;
## that a seat that runs dry ends the round; and that the title lets the pads go. Returns what went wrong.
func selftest_versus_problems() -> PackedStringArray:
	var problems := PackedStringArray()
	var join := show_join()
	if join == null or join.name != "Join":
		problems.append("the join screen did not open")
		return problems
	for device: int in SELFTEST_PADS:
		seats.join(device)
	seats.set_bots(1)
	var race := start_versus()
	if race == null or race.name != "Versus":
		problems.append("the versus race did not open")
		show_title()
		return problems
	var game_match: Match = race.game_match
	var world := game_match.world
	var slots := seats.lineup.size()
	if world.mode != World.MODE_VERSUS or slots != 3 or seats.humans_mask() != 0b011:
		problems.append("the race is not a versus match of two pads and a bot")
		show_title()
		return problems
	var seed_value := world.game_seed
	var bytes: Array[PackedByteArray] = []
	var paused := false
	var still := true
	var resumed := false
	var orphan_bytes := true
	for tick in SELFTEST_TICKS:
		if tick == SELFTEST_PAUSE_TICK or tick == SELFTEST_RESUME_TICK:
			seats.press(PlayerInput.PAUSE)
		if tick == SELFTEST_DISCONNECT_TICK:
			_on_joy_connection_changed(SELFTEST_PADS[1], false)
		var step := seats.step_bytes(slots)
		bytes.append(step)
		var y_bot := world.players[2].y_world
		world.traffic.clear()
		race.step_once(step)
		if tick == SELFTEST_PAUSE_TICK:
			paused = world.phase == World.PAUSED
		elif tick > SELFTEST_PAUSE_TICK and tick < SELFTEST_RESUME_TICK:
			still = still and world.phase == World.PAUSED and world.players[2].y_world == y_bot
		elif tick == SELFTEST_RESUME_TICK:
			resumed = world.phase == World.RUNNING
		if tick >= SELFTEST_DISCONNECT_TICK:
			orphan_bytes = orphan_bytes and step[1] == PlayerInput.BOT
		if tick % 60 == 0:
			race.render()
	if not paused:
		problems.append("versus: the pause press at tick %d did not pause the round" % SELFTEST_PAUSE_TICK)
	elif not still:
		problems.append("versus: the round did not stay paused, or a car moved, before tick %d" % SELFTEST_RESUME_TICK)
	elif not resumed:
		problems.append("versus: the pause press at tick %d did not resume the round" % SELFTEST_RESUME_TICK)
	if world.players[2].distance <= 0.0:
		problems.append("versus: the bot did not drive")
	if not orphan_bytes or not seats.is_orphan(1):
		problems.append("versus: the seat of the pad that went away was not handed to its bot")
	if game_match.phase != Match.PLAYING or world.tick != SELFTEST_TICKS:
		problems.append("versus: the round did not go on for %d ticks" % SELFTEST_TICKS)
	# Determinism: the same seed and bytes, without the screens, give the same match.
	var replay := Match.create(world.cfg, seed_value, slots, 0b011)
	for step: PackedByteArray in bytes:
		replay.world.traffic.clear()
		replay.step(step)
	if replay.checksum() != game_match.checksum():
		problems.append("versus: a replay of the same inputs differs")
	world.players[0].fuel = 0.01
	race.step_once(seats.step_bytes(slots))
	if game_match.phase != Match.ROUND_OVER or game_match.last_round_winner() != 1:
		problems.append("versus: the round did not end with the seat that ran dry")
	race.render()
	if show_title() == null or seats.people() != 0:
		problems.append("versus: could not go back to the title")
	return problems
