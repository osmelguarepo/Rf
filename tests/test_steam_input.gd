extends "res://tests/test_case.gd"
## Steam Input (B4, scripts/input/steam_input.gd; docs/GODOT_PLAN.md §5 and §8 B4, docs/STEAM_INPUT.md): the start
## in the plan's order with the manifest next to the executable, one warning and no other call when Steam does not
## start, --no-steam (also for the tools and the tests), the handles read when a configuration loads, one source of
## pads per session and only once Steam knows every name, Steam's actions as the buttons of a virtual pad of its own
## device (each action name in one set only, buttons held across a set switch for its first frames only), and through a
## real App: a Steam controller that joins a seat, drives it, goes away (0xFF) and comes back to its own seat, single
## player, the menus and the results panels. The Steam singleton is tests/fake_steam.gd, except in
## test_the_real_godotsteam_singleton. Warnings are counted by a Logger of this file; errors fail a test as everywhere
## (tests/run_tests.gd).

const SteamInput := preload("res://scripts/input/steam_input.gd")
const FakeSteam := preload("res://tests/fake_steam.gd")
const S := preload("res://tests/screen_helpers.gd")
const App := preload("res://scripts/app/app.gd")
const Held := preload("res://scripts/input/held.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")
const World := preload("res://scripts/sim/world.gd")
const Car := preload("res://scripts/sim/car.gd")
const Match := preload("res://scripts/sim/match.gd")
const Config := preload("res://scripts/sim/config.gd")

const SEED := 21
## Steam's controller handles (uint64 in Steam).
const H1 := 0x1234567890
const H2 := 77
## A Godot joypad device of these tests (other files use other numbers).
const PAD := 31
## Godot's first joypad device, the one a single pad gets (the smoke test's).
const PAD_0 := 0
const FIRST := SteamInput.DEVICE_BASE
## A tool run in a child Godot by test_the_tools_never_start_steam().
const STEAM_OFF_TOOL := "res://tests/fixtures/steam_off_tool.gd"


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
	fake.name_handles(SteamInput.ACTIONS)
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
	S.release([PAD, PAD_0, FIRST, FIRST + 1])


# --- The adapter ------------------------------------------------------------------------------------------------------


## Plan §5: steamInitEx(480, true), then inputInit(false), setInputActionManifestFilePath(<the manifest>) and
## enableDeviceCallbacks(), in that order, with Steam's three signals connected before the last one. start_engine(),
## which the app calls, hands Steam manifest_path(): run by the editor, as here, the project's own manifest.
func test_steam_starts_in_the_plans_order() -> void:
	adapter.lookup = func() -> Object: return fake
	assert_eq(adapter.start_engine(PackedStringArray()), SteamInput.WAITING)
	assert_eq(fake.names(), ["steamInitEx", "inputInit", "setInputActionManifestFilePath", "enableDeviceCallbacks"])
	assert_eq(fake.calls_of("steamInitEx"), [[480, true]])
	assert_eq(fake.calls_of("inputInit"), [[false]])
	assert_eq(fake.calls_of("setInputActionManifestFilePath"), [[SteamInput.manifest_path()]])
	assert_eq(adapter.manifest, SteamInput.manifest_path())
	assert_eq(SteamInput.manifest_path(), ProjectSettings.globalize_path("res://steam_input/steam_input_manifest.vdf"),
		"run from the editor, the project's manifest")
	assert_true(FileAccess.file_exists(SteamInput.manifest_path()))
	assert_eq(fake.connected_at_enable, 3, "connected before Steam reports the controllers already there")
	assert_eq(warnings.taken(), PackedStringArray())
	assert_eq(adapter.start(fake, "elsewhere.vdf"), SteamInput.WAITING, "a second start does nothing")
	assert_eq(fake.names().size(), 4)
	assert_eq(adapter.state_name(), "waiting")
	adapter.lookup = Callable()


## Where Steam reads the manifest (plan §5): <folder of the executable>/steam_input/steam_input_manifest.vdf in an
## exported game, on Linux as on Windows (Godot's paths use "/" there too), and the project's folder when the editor
## runs the game, wherever the editor's executable is; manifest_path() is that for this run.
func test_the_manifest_is_next_to_the_executable_of_an_exported_game() -> void:
	assert_eq(SteamInput.manifest_path_for(false, "/home/player/games/fuel_rivals/fuel_rivals.x86_64"),
		"/home/player/games/fuel_rivals/steam_input/steam_input_manifest.vdf")
	assert_eq(SteamInput.manifest_path_for(false, "C:/Program Files (x86)/Steam/steamapps/common/Fuel Rivals/fuel_rivals.exe"),
		"C:/Program Files (x86)/Steam/steamapps/common/Fuel Rivals/steam_input/steam_input_manifest.vdf")
	var project := ProjectSettings.globalize_path("res://steam_input/steam_input_manifest.vdf")
	assert_eq(SteamInput.manifest_path_for(true, "/opt/godot/Godot_v4.7.2-stable_linux.x86_64"), project)
	assert_eq(SteamInput.manifest_path_for(true, "C:/Godot/Godot_v4.7.2-stable_win64.exe"), project)
	assert_eq(SteamInput.manifest_path(), SteamInput.manifest_path_for(OS.has_feature("editor"), OS.get_executable_path()))


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
		steam.name_handles(SteamInput.ACTIONS)
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
	var racing_set: Dictionary = SteamInput.ACTIONS[SteamInput.RACING]
	var menus_set: Dictionary = SteamInput.ACTIONS[SteamInput.MENUS]
	assert_eq(racing_set.get("high_gear"), JOY_BUTTON_A)
	assert_eq(racing_set.get("accelerate"), JOY_BUTTON_DPAD_UP)
	assert_eq(menus_set.get("menu_back"), JOY_BUTTON_B)
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


## Steam may apply activateActionSet() only at its next frame, and reports the new set's actions inactive until then. A
## button that a held action of the old set and one of the new set share (Start: menu_start, then pause) stays down
## through the switch, so it makes one press, not two; a button the new set has no action for (B: menu_back) goes up
## at once; once the set is active the buttons follow its actions.
func test_an_action_set_switch_keeps_shared_buttons_held() -> void:
	_start()
	_configure(H1)
	# The same physical buttons, as both sets' actions: Start and B held in the menus.
	for action: String in ["menu_start", "pause", "menu_back"]:
		fake.hold(H1, action)
	assert_eq(_frame(false), [[FIRST, JOY_BUTTON_B, true], [FIRST, JOY_BUTTON_START, true]])
	fake.activation_lag = true
	assert_eq(_frame(true), [[FIRST, JOY_BUTTON_B, false]], "the racing set is not active yet: Start stays down")
	fake.run_frame()
	assert_eq(_frame(true), [], "now it is: pause holds Start, no second press")
	for action: String in ["menu_start", "pause", "menu_back"]:
		fake.hold(H1, action, false)
	assert_eq(_frame(true), [[FIRST, JOY_BUTTON_START, false]])
	# Back to the menus with accelerate held: D-pad up is menu_up's button too, so it stays down while the menus set is
	# pending, and goes up once menu_up reads as not held.
	fake.hold(H1, "accelerate")
	assert_eq(_frame(true), [[FIRST, JOY_BUTTON_DPAD_UP, true]])
	assert_eq(_frame(false), [], "D-pad up is menu_up's too: kept while the menus set is pending")
	fake.run_frame()
	assert_eq(_frame(false), [[FIRST, JOY_BUTTON_DPAD_UP, false]], "menu_up is not held")


## The hold-over is for the switch only: SWITCH_FRAMES frames from a change of the set asked of the controller. If Steam
## still reports the new set's actions inactive after them (it never applies the set), the button held over goes up,
## once, and stays up however long that lasts, until the set is active and its action holds the button again. Without
## a change of the set asked for, an action that reads inactive lets go of its button at once.
func test_the_hold_over_ends_after_the_switch_frames() -> void:
	_start()
	_configure(H1)
	assert_eq(SteamInput.SWITCH_FRAMES, 2, "the frame of the switch and the next")
	fake.hold(H1, "menu_start")
	fake.hold(H1, "pause")
	assert_eq(_frame(false), [[FIRST, JOY_BUTTON_START, true]])
	fake.activation_lag = true
	for i in SteamInput.SWITCH_FRAMES:
		assert_eq(_frame(true), [], "switch frame %d: Start held over" % i)
	assert_eq(_frame(true), [[FIRST, JOY_BUTTON_START, false]], "the racing set still reads inactive: Start goes up")
	var later: Array = []
	for i in 300:
		later.append_array(_frame(true))
	assert_eq(later, [], "and stays up through 300 frames of inactive actions")
	fake.run_frame()
	assert_eq(_frame(true), [[FIRST, JOY_BUTTON_START, true]], "the racing set is active at last: pause holds Start")
	# The same set asked for, but Steam reports it inactive (another set is the active one): no hold-over.
	fake.active_set[H1] = fake.set_handles["menus"]
	assert_eq(_frame(true), [[FIRST, JOY_BUTTON_START, false]], "no switch: an inactive action is not held")
	fake.run_frame()
	assert_eq(_frame(true), [[FIRST, JOY_BUTTON_START, true]])


## ISteamInput's getDigitalActionHandle() takes no set, so a name used in two sets is one handle, the first set's
## action, and Steam ignores the other (Steamworks docs; tests/fake_steam.gd does the same): every name of the adapter's
## ACTIONS is in one set only, and the menus set's own start with "menu_".
func test_every_action_name_is_in_one_set_only() -> void:
	var seen := {}
	for set_name: String in SteamInput.ACTIONS:
		for action: String in SteamInput.ACTIONS[set_name]:
			assert_false(seen.has(action), "%s is in %s and in %s" % [action, seen.get(action, ""), set_name])
			seen[action] = set_name
			if set_name == SteamInput.MENUS:
				assert_true(action.begins_with("menu_"), action)
	assert_eq(seen.size(), 16)
	# A name in both sets, on the fake as on Steam: held, it reads as held in its first set only.
	var steam := FakeSteam.new()
	steam.name_handles({"racing": ["go"], "menus": ["go"]})
	assert_eq(steam.action_handles.size(), 1)
	steam.hold(H1, "go")
	steam.activateActionSet(H1, steam.set_handles["menus"])
	assert_false(steam.getDigitalActionData(H1, steam.action_handles["go"])["state"], "never in the menus set")
	steam.activateActionSet(H1, steam.set_handles["racing"])
	assert_true(steam.getDigitalActionData(H1, steam.action_handles["go"])["state"])


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


## Plan §8 B4 with the real GodotSteam, the one test that starts it: without a Steam client (this sandbox, CI)
## steamInitEx(480) returns status 1, one warning, the singleton is never called again and Godot's pads are read.
## Without the addon (a build without Steam): one warning too. With a Steam client running (a developer's PC): status 0,
## the adapter waits for controllers. With --no-steam on the test run's command line (tools/test.sh --no-steam):
## nothing is started, no warning.
func test_the_real_godotsteam_singleton() -> void:
	var real := SteamInput.new()
	var state := real.start_engine()
	if SteamInput.command_line().has(SteamInput.NO_STEAM):
		assert_eq(state, SteamInput.DISABLED)
		assert_eq(real.init_result, {}, "steamInitEx() was not called")
		assert_eq(warnings.taken(), PackedStringArray())
		print("steam_input: --no-steam: Steam is not started")
		return
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


# --- The tools and the tests on a PC with Steam -----------------------------------------------------------------------


## The tools (tools/smoke.gd, screenshots.gd, scalecheck.gd) never start Steam: they drive synthetic pads, which Steam
## would drop as soon as it took over on a PC where it runs with a controller of its own. tools/tool_base.gd's
## start_app() sets App.no_steam, so the game's _ready() leaves the adapter disabled: no call to GodotSteam, no
## warning, none of Steam's own lines. Only a running tree calls _ready(), so tests/fixtures/steam_off_tool.gd, a tool
## that boots the game with start_app() as the others do, runs in a child Godot.
func test_the_tools_never_start_steam() -> void:
	var result := _run_godot(PackedStringArray(["-s", STEAM_OFF_TOOL]))
	var text: String = result[1]
	assert_eq(result[0], 0, text)
	assert_true(text.contains("steam_off_tool: steam disabled, no_steam true"), text)
	assert_true(text.contains("steam_off_tool: PASS"), text)
	assert_false(text.contains("Steam Input is off"), "no warning: " + text)
	assert_false(text.contains("[S_API]"), "Steam's library was not started: " + text)


## tools/test.sh --no-steam: the runner lets the argument through (any other unknown one fails the run) and the one
## test that starts the real GodotSteam starts nothing then. Runs that test in a child runner.
func test_the_tests_run_with_no_steam() -> void:
	var result := _run_godot(PackedStringArray([
		"-s", "res://tests/run_tests.gd", "--", SteamInput.NO_STEAM,
		"--only=tests/test_steam_input.gd::test_the_real_godotsteam_singleton",
	]))
	var text: String = result[1]
	assert_eq(result[0], 0, text)
	assert_true(text.contains("steam_input: --no-steam: Steam is not started"), text)
	assert_true(text.contains("\n1 passed, 0 failed"), text)
	assert_false(text.contains("[S_API]"), "Steam's library was not started: " + text)
	var other := _run_godot(PackedStringArray(["-s", "res://tests/run_tests.gd", "--", "--no-stem"]))
	assert_eq(other[0], 1, "a misspelt argument still fails the run")
	assert_true((other[1] as String).contains("unknown argument --no-stem"), other[1])


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
	fake.hold(H1, "menu_confirm")
	app._process(S.DT)
	assert_eq(app.seats.seat_of(FIRST), 0, "joined the first seat in that frame")
	fake.hold(H1, "menu_confirm", false)
	app._process(S.DT)
	assert_eq(fake.active_set[H1], fake.set_handles["menus"], "the menus set on the join screen")
	_press(H1, "menu_start")
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


## Two Steam controllers on seats 0 and 1 both go away in a race (0xFF on both seats); the second comes back first and
## takes its own seat by its GUID (steam:<handle>), not the lowest orphan seat, which stays its bot's until the first
## controller comes back to it. Each seat is driven by its own controller again.
func test_steam_controllers_come_back_to_their_own_seats() -> void:
	_boot_app()
	app.show_join()
	_configure(H1)
	_configure(H2)
	_press(H1, "menu_confirm")
	_press(H2, "menu_confirm")
	assert_eq(app.seats.seat_of(FIRST), 0)
	assert_eq(app.seats.seat_of(FIRST + 1), 1)
	_press(H2, "menu_start")
	assert_eq(S.screen_name(app), "Versus", "two people, no bot")
	assert_eq(app.seats.lineup, [0, 1])
	fake.input_device_disconnected.emit(H1)
	fake.input_device_disconnected.emit(H2)
	assert_eq(app.seats.step_bytes(2), PackedByteArray([PlayerInput.BOT, PlayerInput.BOT]), "both bots drive")
	fake.input_device_connected.emit(H2)
	assert_eq(app.seats.seat_of(FIRST + 1), 1, "its own seat, by its GUID")
	assert_true(app.seats.is_orphan(0), "the lower seat waits for its own controller")
	fake.hold(H2, "steer_right")
	app.poll_steam()
	assert_eq(app.seats.step_bytes(2), PackedByteArray([PlayerInput.BOT, Held.to_byte(Held.RIGHT)]))
	fake.input_device_connected.emit(H1)
	assert_eq(app.seats.seat_of(FIRST), 0)
	fake.hold(H1, "brake")
	app.poll_steam()
	assert_eq(app.seats.step_bytes(2), PackedByteArray([Held.to_byte(Held.BRAKE), Held.to_byte(Held.RIGHT)]))


## Single player with a Steam controller, as with a pad: menu_confirm on the title starts a game (1 PLAYER is the first
## choice), the racing set is read there and high gear drives (high gear and throttle, the pad's A), pause pauses, the
## menus set is read while paused, and its menu_start (Start too) resumes.
func test_a_steam_controller_plays_single_player() -> void:
	_boot_app()
	_configure(H1)
	_press(H1, "menu_confirm")
	assert_eq(S.screen_name(app), "Game")
	app.poll_steam()
	assert_eq(fake.active_set[H1], fake.set_handles["racing"])
	fake.hold(H1, "high_gear")
	app.poll_steam()
	assert_eq(app.solo.held(), Held.ACCEL | Held.HIGH_GEAR, "the pad's A")
	var world: World = app.current_screen().world
	for i in 60:
		app.poll_steam()
		S.frame(app)
	assert_gt(world.player().speed, 0.0, "the car drove")
	assert_eq(world.player().gear, Car.GEAR_HIGH, "in high gear")
	_press(H1, "pause")
	assert_eq(world.phase, World.PAUSED)
	app.poll_steam()
	assert_eq(fake.active_set[H1], fake.set_handles["menus"], "the menus set while paused")
	_press(H1, "menu_start")
	assert_eq(world.phase, World.RUNNING)
	app.poll_steam()
	assert_eq(fake.active_set[H1], fake.set_handles["racing"])


## The menus and the race's commands with a Steam controller, as with a pad: on the title menu_down picks VERSUS and
## menu_confirm opens the join screen; there menu_confirm joins, menu_right and menu_left change the bots, menu_back
## leaves the seat, menu_quit goes to the title; in a race pause pauses, and while paused (the menus set) menu_start
## resumes and menu_quit (Back) quits to the title.
func test_menus_and_race_commands_through_steam() -> void:
	_boot_app()
	_configure(H1)
	_press(H1, "menu_down")
	assert_eq(app.current_screen().choice, 1, "VERSUS chosen")
	_press(H1, "menu_confirm")
	assert_eq(S.screen_name(app), "Join")
	_press(H1, "menu_confirm")
	assert_eq(app.seats.seat_of(FIRST), 0)
	assert_eq(app.seats.bots, 1, "a lone person gets a bot")
	_press(H1, "menu_right")
	assert_eq(app.seats.bots, 2)
	_press(H1, "menu_left")
	assert_eq(app.seats.bots, 1)
	_press(H1, "menu_back")
	assert_eq(app.seats.seat_of(FIRST), -1, "back leaves the seat")
	_press(H1, "menu_confirm")
	_press(H1, "menu_quit")
	assert_eq(S.screen_name(app), "Title", "quit goes to the title")
	_press(H1, "menu_confirm")
	_press(H1, "menu_confirm")
	_press(H1, "menu_start")
	assert_eq(S.screen_name(app), "Versus")
	var world: World = app.current_screen().world
	_press(H1, "pause")
	assert_eq(world.phase, World.PAUSED, "pause pauses")
	_press(H1, "menu_start")
	assert_eq(world.phase, World.RUNNING, "and Start resumes")
	_press(H1, "pause")
	_press(H1, "menu_quit")
	assert_eq(S.screen_name(app), "Title", "Back quits a paused race")


## The versus panels with Steam controllers, as with pads (the menus set is read there): after a round, menu_confirm
## (A) from MATCH_CONFIRM_TICKS steps on starts the next one; at the match's end menu_back (B) goes back to the join
## screen, where both controllers keep their seats.
func test_the_results_panels_through_steam() -> void:
	_boot_app()
	app.show_join()
	_configure(H1)
	_configure(H2)
	_press(H1, "menu_confirm")
	_press(H2, "menu_confirm")
	_press(H1, "menu_start")
	assert_eq(S.screen_name(app), "Versus")
	var m: Match = app.current_screen().game_match
	for round_index in Config.MATCH_ROUNDS_MAX:
		if m.phase == Match.MATCH_OVER:
			break
		S.frame(app, 5)
		m.world.players[0].fuel = 0.01
		S.frame(app, 1)
		assert_ne(m.phase, Match.PLAYING, "P1 ran dry: the round is over")
		app.poll_steam()
		assert_eq(fake.active_set[H1], fake.set_handles["menus"], "the menus set on the results")
		if m.phase == Match.ROUND_OVER:
			S.frame(app, Config.MATCH_CONFIRM_TICKS)
			_press(H1, "menu_confirm")
			assert_eq(m.phase, Match.PLAYING, "A starts the next round")
	assert_eq(m.phase, Match.MATCH_OVER)
	assert_eq(m.winner, 1, "P2 won both rounds")
	S.frame(app, Config.MATCH_CONFIRM_TICKS)
	_press(H2, "menu_back")
	assert_eq(S.screen_name(app), "Join", "B goes back to the join screen")
	assert_eq([app.seats.seat_of(FIRST), app.seats.seat_of(FIRST + 1)], [0, 1])


## A Steam controller that starts the race with Start and keeps it held while Steam switches to the
## racing set does not pause the race it just started.
func test_start_held_into_the_race_does_not_pause_it() -> void:
	_boot_app()
	app.show_join()
	_configure(H1)
	_press(H1, "menu_confirm")
	assert_eq(app.seats.seat_of(FIRST), 0)
	fake.activation_lag = true
	fake.hold(H1, "menu_start")
	fake.hold(H1, "pause")
	for i in 4:
		app._process(S.DT)
		fake.run_frame()
	assert_eq(S.screen_name(app), "Versus")
	var world: World = app.current_screen().world
	assert_eq(world.phase, World.RUNNING, "one press of Start: the race runs")
	assert_gt(world.tick, 0)


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
	_press(H1, "menu_confirm")
	assert_eq(app.seats.seat_of(FIRST), 0, "Steam's controller takes the seat")


## Plan §5, "Steam if it has handles": a configuration of the game's actions that loads while Steam has no handle for
## the manifest's names (getActionSetHandle() and getDigitalActionHandle() answer 0: Steam has not loaded the game's
## action manifest) takes nothing over. Godot's pads stay the source, one warning says so for the whole session, and
## no controller is read; one name unknown is enough. The first configuration that loads with every handle takes over,
## with every connected controller of the game's configuration.
func test_no_takeover_while_steam_has_no_handle_for_a_name() -> void:
	fake.set_handles = {}
	fake.action_handles = {}
	fake.action_set_of = {}
	_boot_app()
	app.show_join()
	S.tap(app, PAD, JOY_BUTTON_A)
	S.frame(app)
	assert_eq(app.seats.seat_of(PAD), 0, "a Godot pad joins")
	fake.input_device_connected.emit(H1)
	_configure(H1)
	assert_eq(adapter.state, SteamInput.WAITING, "no takeover")
	assert_eq([takeovers, connections], [0, []], "no virtual pad")
	assert_eq(app.seats.seat_of(PAD), 0, "the Godot pad keeps its seat")
	assert_false(adapter.drops_device(PAD))
	var logged := warnings.taken()
	assert_eq(logged.size(), 1, "one warning")
	if logged.size() == 1:
		assert_true(logged[0].begins_with("Steam Input: Steam has no handle for any action set or action, so"), logged[0])
		assert_true(logged[0].contains(SteamInput.manifest_path()), "it names the manifest: " + logged[0])
	fake.forget_calls()
	app.poll_steam()
	assert_eq(fake.calls, [], "no controller is read")
	S.tap(app, PAD, JOY_BUTTON_B)
	S.frame(app)
	assert_eq(app.seats.seat_of(PAD), -1, "the Godot pad is still read: B leaves the seat")
	S.tap(app, PAD, JOY_BUTTON_A)
	S.frame(app)
	# A second controller, then Steam knowing every name but one: still no takeover, and no second warning.
	_configure(H2)
	fake.name_handles(SteamInput.ACTIONS)
	var quit_handle: int = fake.action_handles["menu_quit"]
	fake.action_handles.erase("menu_quit")
	_configure(H1)
	assert_eq(adapter.state, SteamInput.WAITING, "one name without a handle is enough")
	assert_eq(adapter.set_handles, {}, "no handle kept")
	assert_eq(app.seats.seat_of(PAD), 0)
	assert_eq(warnings.taken().size(), 1, "one warning for the session")
	# Every name: the next configuration takes over, with both controllers; the Godot pad leaves.
	fake.action_handles["menu_quit"] = quit_handle
	_configure(H2)
	assert_eq(adapter.state, SteamInput.ACTIVE)
	assert_eq(takeovers, 1)
	assert_eq(connections, [[FIRST, true], [FIRST + 1, true]])
	assert_eq(adapter.action_handles["menu_quit"], quit_handle)
	assert_eq(app.seats.seat_of(PAD), -1, "Steam is the source now")
	_press(H1, "menu_confirm")
	assert_eq(app.seats.seat_of(FIRST), 0, "the first controller joins")
	assert_eq(warnings.taken().size(), 1)
	# Another session, where Steam knows every name but one: its warning names it.
	var steam := FakeSteam.new()
	steam.name_handles(SteamInput.ACTIONS)
	steam.action_handles.erase("menu_quit")
	var other := SteamInput.new()
	assert_eq(other.start(steam, SteamInput.manifest_path()), SteamInput.WAITING)
	steam.input_configuration_loaded.emit(SteamInput.APP_ID, H1, {"uses_steam_input_api": true})
	assert_eq(other.state, SteamInput.WAITING)
	logged = warnings.taken()
	assert_eq(logged.size(), 2)
	if logged.size() == 2:
		assert_true(logged[1].begins_with("Steam Input: Steam has no handle for menu_quit, so"), logged[1])


## Steam's virtual pads are devices of their own (DEVICE_BASE up), never one of Godot's joypads (0 up): with a Godot
## pad on device 0 seated when Steam takes over, the Steam controller gets another device and its own GUID, device 0
## leaves its seat and is dropped from then on, and the controller joins on its own device.
func test_steam_devices_never_collide_with_godot_pads() -> void:
	_boot_app()
	app.show_join()
	S.tap(app, PAD_0, JOY_BUTTON_A)
	S.frame(app)
	assert_eq(app.seats.seat_of(PAD_0), 0, "a Godot pad on device 0 joins before Steam takes over")
	_configure(H1)
	var device: int = adapter.devices.get(H1, -1)
	assert_ne(device, PAD_0, "the Steam controller is not device 0")
	assert_true(device >= SteamInput.DEVICE_BASE, "a device of its own: %d" % device)
	assert_false(adapter.owns(PAD_0))
	assert_true(adapter.drops_device(PAD_0), "Godot's device 0 is dropped")
	assert_eq(app.seats.seat_of(PAD_0), -1, "and leaves its seat")
	assert_eq(app.guid_of(PAD_0), "", "device 0 keeps the engine's GUID (none for a synthetic pad)")
	assert_eq(app.guid_of(device), "steam:%d" % H1)
	S.tap(app, PAD_0, JOY_BUTTON_A)
	S.frame(app)
	assert_eq(app.seats.seat_of(PAD_0), -1, "device 0's presses are dropped")
	_press(H1, "menu_confirm")
	assert_eq(app.seats.seat_of(device), 0, "the Steam controller joins on its own device")
	assert_eq(app.seats.seat_guid[0], "steam:%d" % H1)


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


## The app activates the racing set while people drive and the menus set elsewhere (paused, between rounds, at the
## end, and on the title and join screens); its seats take Steam's GUIDs.
func test_the_app_reads_the_racing_set_where_people_drive() -> void:
	_boot_app()
	assert_false(app.people_drive(), "the title")
	var game := app.start_game()
	assert_true(app.people_drive(), "a single-player game")
	for phase: int in [World.PAUSED, World.GAME_OVER, World.STAGE_CLEAR]:
		game.world.phase = phase
		assert_false(app.people_drive(), "single player, phase %d" % phase)
	app.show_join()
	assert_false(app.people_drive(), "the join screen")
	app.seats.join(PAD)
	app.seats.set_bots(1)
	var race := app.start_versus()
	assert_true(app.people_drive(), "a versus round")
	race.world.phase = World.PAUSED
	assert_false(app.people_drive(), "paused")
	race.world.phase = World.RUNNING
	for phase: int in [Match.ROUND_OVER, Match.MATCH_OVER]:
		race.game_match.phase = phase
		assert_false(app.people_drive(), "match phase %d" % phase)
	app.show_title()
	assert_eq(app.seats.guid_of.call(PAD), "", "a pad the engine does not know")
	_configure(H1)
	assert_eq(app.seats.guid_of.call(FIRST), "steam:%d" % H1)


## start_steam() starts the adapter with the command line (here given): --no-steam among the arguments, or App.no_steam
## (which the tools set), starts nothing at all; otherwise Steam starts (here the fake). Only the game's _ready() calls
## it: tests boot apps with start().
func test_start_steam_honours_no_steam() -> void:
	app = S.boot(SEED)
	var cases: Array = [
		[PackedStringArray(["--path", ".", SteamInput.NO_STEAM]), false, SteamInput.DISABLED],
		[PackedStringArray(["--seed=3"]), true, SteamInput.DISABLED],
		[PackedStringArray(["--seed=3"]), false, SteamInput.WAITING],
	]
	for each: Array in cases:
		var steam := FakeSteam.new()
		var other := SteamInput.new()
		other.lookup = func() -> Object: return steam
		app.use_steam(other)
		app.no_steam = each[1]
		assert_eq(app.start_steam(each[0]), each[2], str(each))
		assert_eq(steam.names(), [] if each[2] == SteamInput.DISABLED else [
			"steamInitEx", "inputInit", "setInputActionManifestFilePath", "enableDeviceCallbacks"
		], str(each))
		other.lookup = Callable()
	assert_eq(warnings.taken(), PackedStringArray())
	app.steam = null
	assert_eq(app.start_steam(), SteamInput.OFF, "no adapter")
	var app_source := FileAccess.get_file_as_string("res://scripts/app/app.gd")
	assert_true(app_source.contains("func _ready() -> void:\n\tstart()\n\tstart_steam()"), "only the game starts Steam")


# --- helpers ---------------------------------------------------------------------------------------------------------


## GDScript source without its comments and string literals.
static func code_only(source: String) -> String:
	var strings := RegEx.create_from_string("\"(?:[^\"\\\\\\n]|\\\\.)*\"|'(?:[^'\\\\\\n]|\\\\.)*'")
	var out := PackedStringArray()
	for line in strings.sub(source, "\"\"", true).split("\n"):
		out.append(line.get_slice("#", 0))
	return "\n".join(out)


## Runs this Godot headless on this project, as a child process, with these arguments; returns [exit code, output].
static func _run_godot(args: PackedStringArray) -> Array:
	var all := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://")])
	all.append_array(args)
	var output: Array = []
	var code := OS.execute(OS.get_executable_path(), all, output, true)
	var text := ""
	for chunk: Variant in output:
		text += str(chunk)
	return [code, text]


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
