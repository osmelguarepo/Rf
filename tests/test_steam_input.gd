extends "res://tests/test_case.gd"
## Steam Input (B4, scripts/input/steam_input.gd; docs/GODOT_PLAN.md §5 and §8 B4, docs/STEAM_INPUT.md): the start
## in the plan's order, one warning and no other call when Steam does not start, --no-steam, the handles read when a
## configuration loads, one source of pads per session, Steam's actions as the buttons of a virtual pad, and through a
## real App: a Steam controller that joins a seat, drives it, goes away (0xFF) and comes back to the same seat. The
## Steam singleton is tests/fake_steam.gd, except in test_the_real_godotsteam_singleton. Warnings are counted by a
## Logger of this file; errors fail a test as everywhere (tests/run_tests.gd).

const SteamInput := preload("res://scripts/input/steam_input.gd")
const FakeSteam := preload("res://tests/fake_steam.gd")
const S := preload("res://tests/screen_helpers.gd")
const App := preload("res://scripts/app/app.gd")
const Held := preload("res://scripts/input/held.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")
const World := preload("res://scripts/sim/world.gd")
const Car := preload("res://scripts/sim/car.gd")

const SEED := 21
## Steam's controller handles (uint64 in Steam).
const H1 := 0x1234567890
const H2 := 77
## A Godot joypad device of these tests (other files use other numbers).
const PAD := 31
const FIRST := SteamInput.DEVICE_BASE


## Collects the warnings logged while a test runs.
class Warnings extends Logger:
	var _mutex := Mutex.new()
	var _warnings := PackedStringArray()

	func _log_error(
		_function: String,
		_file: String,
		_line: int,
		code: String,
		rationale: String,
		_editor_notify: bool,
		error_type: int,
		_script_backtraces: Array[ScriptBacktrace]
	) -> void:
		if error_type != ERROR_TYPE_WARNING:
			return
		_mutex.lock()
		_warnings.append(rationale if not rationale.is_empty() else code)
		_mutex.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass

	func taken() -> PackedStringArray:
		_mutex.lock()
		var out := _warnings.duplicate()
		_mutex.unlock()
		return out


var warnings: Warnings
var fake: FakeSteam
var adapter: SteamInput
var app: App
## What the adapter emitted: [device, button, pressed] per pad event, [device, connected] per pad connection.
var events: Array = []
var connections: Array = []
var takeovers: int = 0


func before_each() -> void:
	warnings = Warnings.new()
	OS.add_logger(warnings)
	fake = FakeSteam.new()
	fake.name_handles([SteamInput.RACING, SteamInput.MENUS], all_actions())
	adapter = SteamInput.new()
	events = []
	connections = []
	takeovers = 0
	adapter.pad_event.connect(_on_pad_event)
	adapter.pad_connection.connect(_on_pad_connection)
	adapter.took_over.connect(_on_took_over)


func after_each() -> void:
	OS.remove_logger(warnings)
	if app != null:
		S.free_app(app)
		app = null
	adapter = null
	fake = null
	S.release([PAD, FIRST, FIRST + 1])


# --- The adapter ------------------------------------------------------------------------------------------------------


## Plan §5: steamInitEx(480, true), then inputInit(false), setInputActionManifestFilePath(<the manifest>) and
## enableDeviceCallbacks(), in that order, with Steam's three signals connected before the last one.
func test_steam_starts_in_the_plans_order() -> void:
	assert_eq(_start(), SteamInput.WAITING)
	assert_eq(fake.names(), ["steamInitEx", "inputInit", "setInputActionManifestFilePath", "enableDeviceCallbacks"])
	assert_eq(fake.calls_of("steamInitEx"), [[480, true]])
	assert_eq(fake.calls_of("inputInit"), [[false]])
	assert_eq(fake.calls_of("setInputActionManifestFilePath"), [[SteamInput.manifest_path()]])
	assert_true(SteamInput.manifest_path().ends_with("/steam_input/steam_input_manifest.vdf"))
	assert_true(FileAccess.file_exists(SteamInput.manifest_path()), "run from the editor, the project's manifest")
	assert_eq(fake.connected_at_enable, 3, "connected before Steam reports the controllers already there")
	assert_eq(warnings.taken(), PackedStringArray())
	assert_eq(adapter.start(fake, "elsewhere.vdf"), SteamInput.WAITING, "a second start does nothing")
	assert_eq(fake.names().size(), 4)
	assert_eq(adapter.state_name(), "waiting")


## Plan §5 and §8 B4: a status other than 0 (1 without a Steam client) gives exactly one warning, and Steam is never
## called again: not by frames, not by its signals, not by a second start. A result without a status counts as one.
func test_a_failed_start_warns_once_and_never_calls_steam_again() -> void:
	var results: Array[Dictionary] = [
		{"status": 1, "verbal": "Failed to load module 'steamclient.so'"},
		{"status": 2, "verbal": "No Steam client"},
		{"status": 3, "verbal": "Version mismatch"},
		{},
	]
	var count := 0
	for result: Dictionary in results:
		var steam := FakeSteam.new()
		steam.name_handles([SteamInput.RACING, SteamInput.MENUS], all_actions())
		steam.init_result = result
		var failed := SteamInput.new()
		assert_eq(failed.start(steam, SteamInput.manifest_path()), SteamInput.UNAVAILABLE, str(result))
		assert_null(failed.singleton)
		for i in 4:
			assert_eq(failed.frame(i % 2 == 0), 0)
		steam.input_device_connected.emit(H1)
		steam.input_configuration_loaded.emit(480, H1, {"uses_steam_input_api": true})
		assert_eq(failed.start(steam, SteamInput.manifest_path()), SteamInput.UNAVAILABLE)
		assert_eq(steam.names(), ["steamInitEx"], "no call after steamInitEx: %s" % result)
		count += 1
		var logged := warnings.taken()
		assert_eq(logged.size(), count, "exactly one warning: %s" % result)
		assert_true(logged[-1].contains("steamInitEx(480) returned status %s" % result.get("status", -1)), logged[-1])
		assert_false(failed.drops(_pad_button(PAD, JOY_BUTTON_A)), "Godot's pads are read")
		assert_false(failed.drops_device(PAD))


## --no-steam, before or after "--": the singleton is not even looked up; no call, no warning.
func test_no_steam_makes_no_call_and_no_warning() -> void:
	var lookups: Array[int] = [0]
	var source := fake
	var find := func() -> Object:
		lookups[0] += 1
		return source
	adapter.lookup = find
	assert_eq(adapter.start_engine(PackedStringArray(["--path", ".", "--no-steam", "--seed=3"])), SteamInput.DISABLED)
	assert_eq(adapter.frame(true), 0)
	assert_eq(adapter.start(fake, SteamInput.manifest_path()), SteamInput.DISABLED, "no start afterwards either")
	assert_eq(lookups[0], 0)
	assert_eq(fake.calls, [])
	assert_eq(warnings.taken(), PackedStringArray())
	assert_false(adapter.drops(_pad_button(PAD, JOY_BUTTON_A)))
	# Without the argument the same adapter setup starts Steam.
	var other := SteamInput.new()
	other.lookup = find
	assert_eq(other.start_engine(PackedStringArray(["--seed=3"])), SteamInput.WAITING)
	assert_eq(lookups[0], 1)
	assert_eq(fake.names()[0], "steamInitEx")
	other.lookup = Callable()
	adapter.lookup = Callable()


## Without GodotSteam (a build without Steam, or the addon left out) and with a singleton that lacks GodotSteam's
## methods: one warning each, no call, Godot's pads.
func test_without_godotsteam_one_warning_and_godot_pads() -> void:
	adapter.lookup = func() -> Object: return null
	assert_eq(adapter.start_engine(PackedStringArray()), SteamInput.UNAVAILABLE)
	var logged := warnings.taken()
	assert_eq(logged.size(), 1)
	assert_true(logged[0].contains("GodotSteam (addons/godotsteam/) is not loaded"), logged[0])
	assert_eq(adapter.frame(true), 0)
	assert_false(adapter.drops(_pad_button(PAD, JOY_BUTTON_A)))
	var other := SteamInput.new()
	assert_eq(other.start(RefCounted.new(), SteamInput.manifest_path()), SteamInput.UNAVAILABLE)
	assert_eq(warnings.taken().size(), 2)
	assert_true(warnings.taken()[1].contains("has no steamInitEx()"))
	adapter.lookup = Callable()


## Plan §5: the handles are read when Steam has loaded a controller's configuration. Before that, no controller is
## read and Godot's pads are the source; then Steam takes over (once) and the controller gets the first device.
func test_handles_are_read_when_a_configuration_loads() -> void:
	_start()
	fake.forget_calls()
	fake.input_device_connected.emit(H1)
	assert_eq(adapter.frame(true), 0)
	assert_eq(fake.calls, [], "nothing read before a configuration has loaded")
	assert_eq(adapter.state, SteamInput.WAITING)
	assert_false(adapter.drops(_pad_button(PAD, JOY_BUTTON_A)), "Godot's pads meanwhile")
	assert_eq(connections, [])
	_configure(H1)
	assert_eq(fake.calls_of("getActionSetHandle"), [["racing"], ["menus"]])
	var asked: Array = []
	for args: Array in fake.calls_of("getDigitalActionHandle"):
		asked.append(args[0])
	var expected: Array = []
	for set_name: String in SteamInput.ACTIONS:
		for action: String in SteamInput.ACTIONS[set_name]:
			expected.append(action)
	assert_eq(asked, expected)
	assert_eq(adapter.set_handles, {"racing": fake.set_handles["racing"], "menus": fake.set_handles["menus"]})
	assert_eq(adapter.action_handles["accelerate"], fake.action_handles["accelerate"])
	assert_eq(adapter.state, SteamInput.ACTIVE)
	assert_eq(takeovers, 1)
	assert_eq(connections, [[FIRST, true]])


## Plan §5, one source per session: once Steam has a controller, Godot's pads are dropped for good (buttons, sticks,
## comings and goings), even after every Steam controller has gone; the keyboard stays.
func test_steam_with_handles_is_the_only_source() -> void:
	_start()
	_configure(H1)
	assert_true(adapter.drops(_pad_button(PAD, JOY_BUTTON_A)))
	var motion := InputEventJoypadMotion.new()
	motion.device = PAD
	assert_true(adapter.drops(motion))
	assert_true(adapter.drops_device(PAD))
	assert_false(adapter.drops(_pad_button(FIRST, JOY_BUTTON_A)), "Steam's own")
	assert_false(adapter.drops_device(FIRST))
	var key := InputEventKey.new()
	key.physical_keycode = KEY_ENTER
	assert_false(adapter.drops(key), "the keyboard stays")
	fake.input_device_disconnected.emit(H1)
	assert_true(adapter.drops(_pad_button(PAD, JOY_BUTTON_A)), "still Steam's session")
	_configure(H2)
	assert_eq(takeovers, 1, "taken over once")


## A controller whose layout is a legacy gamepad template (no game actions) is left to Steam's emulated pad, which
## Godot reads: no takeover.
func test_a_gamepad_template_leaves_godot_pads() -> void:
	_start()
	fake.input_device_connected.emit(H1)
	_configure(H1, false)
	assert_eq(adapter.state, SteamInput.WAITING)
	assert_eq(takeovers, 0)
	assert_false(adapter.drops(_pad_button(PAD, JOY_BUTTON_A)))
	assert_eq(connections, [])


## Each action of the active set holds down its button of the virtual pad (SteamInput.ACTIONS: the gamepad mapping
## of pads.gd and nav.gd), each change is one event, the active set is activated on the controller every frame, and
## the other set's actions are not read.
func test_actions_hold_the_buttons_of_a_virtual_pad() -> void:
	_start()
	_configure(H1)
	for set_name: String in SteamInput.ACTIONS:
		var racing := set_name == SteamInput.RACING
		var actions: Dictionary = SteamInput.ACTIONS[set_name]
		for action: String in actions:
			var button: int = actions[action]
			fake.hold(H1, action)
			assert_eq(_frame(racing), [[FIRST, button, true]], "%s %s" % [set_name, action])
			assert_eq(fake.active_set[H1], fake.set_handles[set_name])
			assert_eq(_frame(racing), [], "nothing changed")
			fake.hold(H1, action, false)
			assert_eq(_frame(racing), [[FIRST, button, false]])
	assert_eq(SteamInput.ACTIONS[SteamInput.RACING]["high_gear"], JOY_BUTTON_A)
	assert_eq(SteamInput.ACTIONS[SteamInput.RACING]["accelerate"], JOY_BUTTON_DPAD_UP)
	assert_eq(SteamInput.ACTIONS[SteamInput.MENUS]["back"], JOY_BUTTON_B)
	# Two actions on one button (high gear and confirm, the pad's A) hold it once.
	fake.hold(H1, "high_gear")
	fake.hold(H1, "confirm")
	assert_eq(_frame(true), [[FIRST, JOY_BUTTON_A, true]])
	fake.hold(H1, "high_gear", false)
	assert_eq(_frame(true), [], "confirm still holds A")
	fake.hold(H1, "confirm", false)
	assert_eq(_frame(true), [[FIRST, JOY_BUTTON_A, false]])
	# Two buttons at once; the menus set does not read the racing actions, so their buttons go up.
	fake.hold(H1, "accelerate")
	fake.hold(H1, "steer_right")
	assert_eq(_frame(true), [[FIRST, JOY_BUTTON_DPAD_UP, true], [FIRST, JOY_BUTTON_DPAD_RIGHT, true]])
	assert_eq(_frame(false), [[FIRST, JOY_BUTTON_DPAD_UP, false], [FIRST, JOY_BUTTON_DPAD_RIGHT, false]])
	assert_eq(fake.active_set[H1], fake.set_handles["menus"])


## Each controller gets its own device and keeps it, with its GUID, when it goes away and comes back. Going away lets
## go of its buttons first; a controller that has gone is not read.
func test_controllers_keep_their_device_and_guid() -> void:
	_start()
	fake.input_device_connected.emit(H1)
	fake.input_device_connected.emit(H2)
	_configure(H1)
	assert_eq(connections, [[FIRST, true]], "H2's configuration has not loaded yet")
	_configure(H2)
	assert_eq(connections, [[FIRST, true], [FIRST + 1, true]])
	assert_eq(adapter.guid_of(FIRST), "steam:%d" % H1)
	assert_eq(adapter.guid_of(FIRST + 1), "steam:77")
	assert_eq(adapter.guid_of(PAD), "")
	assert_true(adapter.owns(FIRST + 1))
	assert_false(adapter.owns(PAD))
	fake.hold(H1, "accelerate")
	assert_eq(_frame(true), [[FIRST, JOY_BUTTON_DPAD_UP, true]])
	connections = []
	events = []
	fake.input_device_disconnected.emit(H1)
	assert_eq(events, [[FIRST, JOY_BUTTON_DPAD_UP, false]], "it lets go first")
	assert_eq(connections, [[FIRST, false]])
	fake.forget_calls()
	assert_eq(_frame(true), [])
	for args: Array in fake.calls_of("getDigitalActionData"):
		assert_eq(args[0], H2, "only the controller still here is read")
	fake.input_device_connected.emit(H1)
	assert_eq(connections, [[FIRST, false], [FIRST, true]], "back on its own device")
	assert_eq(adapter.guid_of(FIRST), "steam:%d" % H1)
	assert_eq(_frame(true), [[FIRST, JOY_BUTTON_DPAD_UP, true]])


## Plan §5: steam_input.gd never names GodotSteam's class (only the singleton's name, as a string), so it compiles and
## runs without the addon; nor does the app.
func test_the_adapter_never_names_the_steam_class() -> void:
	var name := RegEx.create_from_string("\\bSteam\\b")
	for path: String in ["res://scripts/input/steam_input.gd", "res://scripts/app/app.gd"]:
		var code := code_only(FileAccess.get_file_as_string(path))
		assert_gt(code.length(), 1000, path)
		assert_eq(name.search_all(code).size(), 0, "%s names Steam outside strings and comments" % path)
	var source := FileAccess.get_file_as_string("res://scripts/input/steam_input.gd")
	for piece: String in ["Engine.has_singleton(SINGLETON)", "Engine.get_singleton(SINGLETON)",
			'call("steamInitEx", APP_ID, true)']:
		assert_true(source.contains(piece), piece)
	assert_eq(SteamInput.SINGLETON, "Steam")
	assert_eq(SteamInput.APP_ID, 480)
	# The check itself finds the name in code.
	assert_eq(name.search_all(code_only("var x = Steam.steamInit() # Steam\nvar s = \"Steam\"")).size(), 1)


## Plan §8 B4 with the real GodotSteam: without a Steam client (this sandbox, CI) steamInitEx(480) returns status 1,
## one warning, the singleton is never called again and Godot's pads are read. Without the addon (a build without
## Steam): one warning too. With a Steam client running (a developer's PC): status 0, the adapter waits for
## controllers.
func test_the_real_godotsteam_singleton() -> void:
	var real := SteamInput.new()
	var state := real.start_engine(PackedStringArray())
	if not Engine.has_singleton("Steam"):
		assert_eq(state, SteamInput.UNAVAILABLE)
		assert_eq(warnings.taken().size(), 1)
		print("steam_input: no GodotSteam: one warning, Godot's pads")
		return
	var status: Variant = real.init_result.get("status")
	print("steam_input: GodotSteam %s, steamInitEx(480) returned status %s (%s)" % [
		Engine.get_singleton("Steam").call("get_godotsteam_version"), status, real.init_result.get("verbal", "")
	])
	assert_true(status is int, "a status")
	if status == 0:
		assert_eq(state, SteamInput.WAITING, "a Steam client runs here")
		return
	assert_eq(state, SteamInput.UNAVAILABLE)
	assert_null(real.singleton)
	assert_eq(warnings.taken().size(), 1)
	assert_eq(real.frame(true), 0)
	assert_false(real.drops(_pad_button(PAD, JOY_BUTTON_A)))


# --- Through the app --------------------------------------------------------------------------------------------------


## Plan §8 B4: a Steam controller joins the join screen's first seat with confirm, starts the race with start, drives
## its seat's car with the same byte as a pad (the racing set is active there), goes away (its seat's byte is 0xFF:
## its bot drives, the seat stays its) and comes back to the same seat.
func test_a_steam_controller_joins_drives_leaves_and_comes_back() -> void:
	_boot_app()
	app.show_join()
	_configure(H1)
	assert_eq(app.guid_of(FIRST), "steam:%d" % H1)
	# The app's own frame reads Steam before the screen runs.
	fake.hold(H1, "confirm")
	app._process(S.DT)
	assert_eq(app.seats.seat_of(FIRST), 0, "joined the first seat in that frame")
	fake.hold(H1, "confirm", false)
	app._process(S.DT)
	assert_eq(fake.active_set[H1], fake.set_handles["menus"], "the menus set on the join screen")
	_press(H1, "start")
	assert_eq(S.screen_name(app), "Versus", "the race started: one person and the bot a lone person gets")
	app.poll_steam()
	assert_eq(fake.active_set[H1], fake.set_handles["racing"], "the racing set in the race")
	var slot := app.seats.lineup.find(0)
	assert_eq(app.seats.humans_mask(), 1 << slot)
	fake.hold(H1, "accelerate")
	fake.hold(H1, "steer_left")
	app.poll_steam()
	var byte: int = app.seats.step_bytes(app.seats.lineup.size())[slot]
	assert_eq(byte, Held.to_byte(Held.ACCEL | Held.LEFT), "the pad's byte for throttle and left")
	var world: World = app.current_screen().world
	var car: Car = world.players[slot]
	var x := car.x
	for i in 60:
		app.poll_steam()
		S.frame(app)
	assert_gt(car.speed, 0.0, "the car drove")
	assert_lt(car.x, x, "to the left")
	fake.input_device_disconnected.emit(H1)
	assert_false(Input.is_joy_button_pressed(FIRST, JOY_BUTTON_DPAD_UP), "its buttons let go")
	assert_true(app.seats.is_orphan(0), "the seat stays a person's")
	assert_eq(app.seats.step_bytes(app.seats.lineup.size())[slot], PlayerInput.BOT, "its bot drives")
	fake.input_device_connected.emit(H1)
	assert_eq(app.seats.seat_of(FIRST), 0, "back on its seat")
	app.poll_steam()
	assert_eq(app.seats.step_bytes(app.seats.lineup.size())[slot], Held.to_byte(Held.ACCEL | Held.LEFT))


## The menus and the race's commands with a Steam controller, as with a pad: on the title menu_down picks VERSUS and
## confirm opens the join screen; there confirm joins, menu_right and menu_left change the bots, back leaves the seat,
## quit goes to the title; in a race pause pauses and resumes, and back quits a paused race to the title.
func test_menus_and_race_commands_through_steam() -> void:
	_boot_app()
	_configure(H1)
	_press(H1, "menu_down")
	assert_eq(app.current_screen().choice, 1, "VERSUS chosen")
	_press(H1, "confirm")
	assert_eq(S.screen_name(app), "Join")
	_press(H1, "confirm")
	assert_eq(app.seats.seat_of(FIRST), 0)
	assert_eq(app.seats.bots, 1, "a lone person gets a bot")
	_press(H1, "menu_right")
	assert_eq(app.seats.bots, 2)
	_press(H1, "menu_left")
	assert_eq(app.seats.bots, 1)
	_press(H1, "back")
	assert_eq(app.seats.seat_of(FIRST), -1, "back leaves the seat")
	_press(H1, "confirm")
	_press(H1, "quit")
	assert_eq(S.screen_name(app), "Title", "quit goes to the title")
	_press(H1, "confirm")
	_press(H1, "confirm")
	_press(H1, "start")
	assert_eq(S.screen_name(app), "Versus")
	var world: World = app.current_screen().world
	_press(H1, "pause")
	assert_eq(world.phase, World.PAUSED, "pause pauses")
	_press(H1, "pause")
	assert_eq(world.phase, World.RUNNING, "and resumes")
	_press(H1, "pause")
	_press(H1, "back")
	assert_eq(S.screen_name(app), "Title", "back quits a paused race")


## One source per session in the app: a Godot pad seated before Steam takes over leaves its seat; afterwards Godot's
## pads are not read (events, comings and goings); Steam's controller takes the seat.
func test_godot_pads_leave_when_steam_takes_over() -> void:
	_boot_app()
	app.show_join()
	S.tap(app, PAD, JOY_BUTTON_A)
	S.frame(app)
	assert_eq(app.seats.seat_of(PAD), 0, "a Godot pad joins while Steam has no controller")
	_configure(H1)
	assert_eq(app.seats.seat_of(PAD), -1, "it leaves when Steam takes over")
	assert_false(app.seats.pads.devices.has(PAD))
	assert_false(app.solo.pads.devices.has(PAD))
	S.tap(app, PAD, JOY_BUTTON_A)
	S.frame(app)
	assert_eq(app.seats.seat_of(PAD), -1, "its events are dropped")
	app._on_joy_connection_changed(PAD, true)
	assert_false(app.seats.pads.devices.has(PAD), "and its comings and goings")
	_press(H1, "confirm")
	assert_eq(app.seats.seat_of(FIRST), 0, "Steam's controller takes the seat")


## Without a controller of Steam's own, or when Steam did not start, the app reads Godot's pads and Steam is not
## read.
func test_without_steam_controllers_the_app_reads_godot_pads() -> void:
	_boot_app()
	app.show_join()
	fake.forget_calls()
	app.poll_steam()
	assert_eq(fake.calls, [])
	S.tap(app, PAD, JOY_BUTTON_A)
	S.frame(app)
	assert_eq(app.seats.seat_of(PAD), 0)
	var failed := FakeSteam.new()
	failed.init_result = {"status": 1, "verbal": "no Steam"}
	var other := SteamInput.new()
	app.use_steam(other)
	other.start(failed, SteamInput.manifest_path())
	app.poll_steam()
	S.tap(app, PAD, JOY_BUTTON_B)
	S.frame(app)
	assert_eq(app.seats.seat_of(PAD), -1, "B leaves the seat: the pad is still read")
	assert_eq(failed.names(), ["steamInitEx"])
	assert_eq(warnings.taken().size(), 1)


## The app activates the racing set on the screens where people drive and the menus set elsewhere; its seats take
## Steam's GUIDs; start_steam() goes through start_engine().
func test_the_app_reads_the_racing_set_where_people_drive() -> void:
	_boot_app()
	assert_false(app.on_race_screen(), "the title")
	app.start_game()
	assert_true(app.on_race_screen(), "the single-player game")
	app.show_join()
	assert_false(app.on_race_screen(), "the join screen")
	app.seats.join(PAD)
	app.seats.set_bots(1)
	app.start_versus()
	assert_true(app.on_race_screen(), "the versus race")
	app.show_title()
	assert_eq(app.seats.guid_of.call(PAD), "", "a pad the engine does not know")
	_configure(H1)
	assert_eq(app.seats.guid_of.call(FIRST), "steam:%d" % H1)
	var app_source := FileAccess.get_file_as_string("res://scripts/app/app.gd")
	assert_true(app_source.contains("steam.start_engine()"), "start_steam() honours --no-steam")
	assert_true(app_source.contains("func _ready() -> void:\n\tstart()\n\tstart_steam()"), "only the game starts Steam")


# --- helpers ---------------------------------------------------------------------------------------------------------


## Every action name of the manifest's sets, each once.
static func all_actions() -> Array:
	var out: Array = []
	for set_name: String in SteamInput.ACTIONS:
		for action: String in SteamInput.ACTIONS[set_name]:
			if not out.has(action):
				out.append(action)
	return out


## GDScript source without its comments and string literals.
static func code_only(source: String) -> String:
	var strings := RegEx.create_from_string("\"(?:[^\"\\\\\\n]|\\\\.)*\"|'(?:[^'\\\\\\n]|\\\\.)*'")
	var out := PackedStringArray()
	for line in strings.sub(source, "\"\"", true).split("\n"):
		out.append(line.get_slice("#", 0))
	return "\n".join(out)


func _start() -> int:
	return adapter.start(fake, SteamInput.manifest_path())


## Steam has loaded a controller's configuration: the game's actions (api) or a gamepad template.
func _configure(handle: int, api: bool = true) -> void:
	fake.input_configuration_loaded.emit(SteamInput.APP_ID, handle, {
		"mapping_creator": 0, "major_revision": 0, "minor_revision": 0, "uses_steam_input_api": api,
		"uses_gamepad_api": not api,
	})


## One frame of the adapter; returns the pad events it emitted.
func _frame(racing: bool) -> Array:
	events = []
	adapter.frame(racing)
	return events


## A real App with the adapter of this test, started on the fake.
func _boot_app() -> void:
	app = S.boot(SEED)
	app.use_steam(adapter)
	assert_eq(_start(), SteamInput.WAITING)


## An action pressed and let go on a controller, as frames of the app see it: the adapter's frame, then the screen's.
func _press(handle: int, action: String) -> void:
	fake.hold(handle, action)
	app.poll_steam()
	S.frame(app)
	fake.hold(handle, action, false)
	app.poll_steam()
	S.frame(app)


static func _pad_button(device: int, button: JoyButton) -> InputEventJoypadButton:
	var event := InputEventJoypadButton.new()
	event.device = device
	event.button_index = button
	event.pressed = true
	return event


func _on_pad_event(event: InputEventJoypadButton) -> void:
	events.append([event.device, int(event.button_index), event.pressed])


func _on_pad_connection(device: int, connected: bool) -> void:
	connections.append([device, connected])


func _on_took_over() -> void:
	takeovers += 1
