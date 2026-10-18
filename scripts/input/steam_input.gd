extends RefCounted
## Steam Input (B4; docs/GODOT_PLAN.md §5, docs/DECISIONES_MULTIJUGADOR.md §1, docs/STEAM_INPUT.md). Under Steam every
## controller (up to 16, of any make, Remote Play Together guests' too) is read through the game's action manifest,
## steam_input/steam_input_manifest.vdf, and this adapter turns each one into a pad of the game: a virtual joypad
## device whose button events the app parses into Godot's Input. seats.gd, nav.gd and local_input.gd then read a Steam
## controller exactly as a pad: held controls with Pads.held_of(device), presses and menu commands from its events, a
## seat that goes to its bot (0xFF) when the controller goes away and comes back to it when it returns.
##
## GodotSteam (addons/godotsteam/) is optional, and this script never names its class: the engine singleton is looked
## up with Engine.has_singleton() and Engine.get_singleton() and every call goes through call(), so the game compiles
## and runs without the addon (the export presets without Steam leave it out) and without a Steam client.
##
## - start_engine(): nothing at all with --no-steam (before or after "--"); without the singleton, one push_warning.
##   Otherwise start(singleton, manifest_path()).
## - start(): call("steamInitEx", APP_ID, true) (true: GodotSteam runs Steam's callbacks every frame). Any status but 0
##   (1 without a Steam client) gives exactly one push_warning, and the singleton is never called again. With status 0:
##   inputInit(false), then setInputActionManifestFilePath(manifest), then the three signals below are connected and
##   enableDeviceCallbacks() is called, which reports every controller already connected.
## - Handles. When Steam has loaded a controller's configuration (input_configuration_loaded), the adapter reads the
##   handles of the manifest's action sets and actions. Steam answers 0 for a name it does not know: before a
##   configuration has loaded, or when it has not loaded the game's manifest (a wrong path, a file it refused, the App
##   ID's own configuration). The adapter takes the controller only when no handle is 0 (both sets and all 16
##   actions); otherwise it pushes one warning (once per session) and the game goes on reading Godot's pads, until a
##   configuration loads with every handle. It never takes a controller whose layout is a legacy gamepad one
##   (uses_steam_input_api false: Steam then emulates a pad, which Godot reads itself). input_device_connected and
##   input_device_disconnected follow controllers coming and going. A controller keeps its handle when it comes back
##   (ISteamInput: "This handle will consistently identify a controller, even if it is disconnected and re-connected"),
##   so it keeps its device and its GUID, and its seat.
## - One source of pads per session. Until Steam has taken a controller the game reads Godot's pads; from the first
##   one on it reads Steam's only (took_over), for the rest of the session: the app forgets Godot's pads and drops
##   their events (drops(), drops_device()), since the same controller would otherwise arrive twice, through Steam and
##   through the system.
## - frame(racing), every frame before the screen runs: for each controller, activateActionSet() of the racing set
##   (while people drive: App.people_drive()) or the menus set (menus, pause, results), then getDigitalActionData() of
##   that set's actions. Each action holds down a button of the virtual pad (ACTIONS), and each button that goes down or
##   up is an InputEventJoypadButton (pad_event) on the controller's device: DEVICE_BASE for the first controller of the
##   session, DEVICE_BASE + 1 for the next, never one of Godot's own joypad devices. A controller that goes away lets go
##   of its buttons first, then pad_connection(device, false).
##
## So a Steam controller drives as the gamepad mapping of pads.gd: accelerate holds the pad's D-pad up (throttle),
## brake down, steering left and right, high gear the pad's A (high gear and throttle), pause its Start (pause and
## confirm), confirm its A (a pad without a seat takes an orphan seat with it) and back its Back (Select). In the menus
## set the directions are the D-pad, menu_confirm A, menu_back B (leave a seat, leave the results), menu_start Start
## (start, resume) and menu_quit Back (to the title). The price of going through a pad: an action is read as its
## button, so confirm bound apart from high gear also gives high gear while held, as the pad's A does.
##
## Every action name is unique across the sets (the menus set's start with "menu_"): getDigitalActionHandle() takes no
## set, so Steam gives a name used in two sets one handle and ignores the other set's action (ISteamInput docs).

## Emitted for each button of a virtual pad that goes down or up: the app parses it into Input and routes it.
signal pad_event(event: InputEventJoypadButton)
## Emitted when a controller's virtual pad comes (true) or goes (false), as Input.joy_connection_changed would.
signal pad_connection(device: int, connected: bool)
## Emitted once, when Steam becomes the session's source of pads.
signal took_over

const SINGLETON := "Steam"
## Spacewar, Valve's App ID for development (docs/DECISIONES_MULTIJUGADOR.md §1). The game's own replaces it.
const APP_ID := 480
## Turns Steam Input off: no call to Steam at all.
const NO_STEAM := "--no-steam"
## The action manifest, relative to the executable's folder (the project's folder when the editor runs the game).
const MANIFEST := "steam_input/steam_input_manifest.vdf"
## The virtual devices of Steam's controllers start here, far from Godot's own joypads (0 up).
const DEVICE_BASE := 1000
## Frames, counting the one where a controller's requested action set changes, during which a button whose actions
## all read inactive keeps its state (Steam may apply activateActionSet() at its next frame only). See frame().
const SWITCH_FRAMES := 2

## What the adapter is doing.
const OFF := 0
## --no-steam: Steam was never looked for.
const DISABLED := 1
## No GodotSteam, or Steam did not start: the game reads Godot's pads.
const UNAVAILABLE := 2
## Steam started and has no controller of its own yet: the game reads Godot's pads.
const WAITING := 3
## Steam is the session's source of pads.
const ACTIVE := 4
const STATE_NAMES := ["off", "disabled", "unavailable", "waiting", "active"]

## The manifest's action sets.
const RACING := "racing"
const MENUS := "menus"
## Per action set: each digital action of the manifest and the button of the virtual pad it holds down. No name may be
## in both sets (see the class comment).
const ACTIONS := {
	RACING: {
		"accelerate": JOY_BUTTON_DPAD_UP,
		"brake": JOY_BUTTON_DPAD_DOWN,
		"steer_left": JOY_BUTTON_DPAD_LEFT,
		"steer_right": JOY_BUTTON_DPAD_RIGHT,
		"high_gear": JOY_BUTTON_A,
		"confirm": JOY_BUTTON_A,
		"pause": JOY_BUTTON_START,
		"back": JOY_BUTTON_BACK,
	},
	MENUS: {
		"menu_up": JOY_BUTTON_DPAD_UP,
		"menu_down": JOY_BUTTON_DPAD_DOWN,
		"menu_left": JOY_BUTTON_DPAD_LEFT,
		"menu_right": JOY_BUTTON_DPAD_RIGHT,
		"menu_confirm": JOY_BUTTON_A,
		"menu_back": JOY_BUTTON_B,
		"menu_start": JOY_BUTTON_START,
		"menu_quit": JOY_BUTTON_BACK,
	},
}
## The singleton's methods and signals the adapter uses; a GodotSteam without one of them counts as no GodotSteam.
const METHODS := [
	"steamInitEx", "inputInit", "setInputActionManifestFilePath", "enableDeviceCallbacks", "getActionSetHandle",
	"getDigitalActionHandle", "activateActionSet", "getDigitalActionData",
]
const SIGNALS := ["input_device_connected", "input_device_disconnected", "input_configuration_loaded"]

var state: int = OFF
## The singleton while it may be called: null before start() and for good once Steam did not start.
var singleton: Object = null
## steamInitEx()'s result ({"status": int, "verbal": String}), or {} if it was never called.
var init_result: Dictionary = {}
## The manifest path given to Steam.
var manifest: String = ""
## Looks up the engine singleton, or returns null. A test sets its own.
var lookup: Callable = engine_singleton
## Action set name -> handle, and action name -> handle, as read on the last configuration that loaded with every
## handle (none 0); empty until one has.
var set_handles: Dictionary = {}
var action_handles: Dictionary = {}
## True once the warning about names Steam knows no handle for has been pushed (once per session).
var warned_unknown: bool = false
## Steam input handle -> virtual device, for each controller this session has taken (a handle keeps its device).
var devices: Dictionary = {}
## Handles of the controllers Steam reports connected now, in the order they came.
var connected: Array[int] = []
## Handles whose configuration uses the Steam Input API (the game's actions), in the order they came.
var configured: Array[int] = []
## Handles whose virtual pad is announced (pad_connection true) and read every frame.
var announced: Array[int] = []
## Virtual device -> the buttons it holds down now (1 << JoyButton each).
var held: Dictionary = {}
## Steam input handle -> the action set (RACING or MENUS) frame() asked the controller for last, and the frames left in
## which a button of inactive actions keeps its state since that changed (SWITCH_FRAMES at a change, then down to 0).
var requested_set: Dictionary = {}
var switch_frames: Dictionary = {}


## The engine's GodotSteam singleton, or null without the addon.
static func engine_singleton() -> Object:
	return Engine.get_singleton(SINGLETON) if Engine.has_singleton(SINGLETON) else null


## Where Steam reads the action manifest for this run of the game: manifest_path_for() with this executable.
static func manifest_path() -> String:
	return manifest_path_for(OS.has_feature("editor"), OS.get_executable_path())


## Where Steam reads the action manifest: next to the executable at exe_path in an exported game, or in the project's
## folder when the editor runs the game (is_editor; the editor's executable lives elsewhere).
static func manifest_path_for(is_editor: bool, exe_path: String) -> String:
	if is_editor:
		return ProjectSettings.globalize_path("res://" + MANIFEST)
	return exe_path.get_base_dir().path_join(MANIFEST)


## The command line's arguments, before and after "--" (Steam's launch options come before it).
static func command_line() -> PackedStringArray:
	var args := OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	return args


## Starts Steam Input for the game (the app calls it once): see the class comment. Returns the state.
func start_engine(args: PackedStringArray = command_line()) -> int:
	if state != OFF:
		return state
	if args.has(NO_STEAM):
		state = DISABLED
		print_verbose("Steam Input: off (%s)" % NO_STEAM)
		return state
	var found: Variant = lookup.call()
	return start(found as Object, manifest_path())


## Starts Steam Input on a singleton (GodotSteam's, or a test's) with a manifest path. Returns the state.
func start(p_singleton: Object, p_manifest: String) -> int:
	if state != OFF:
		return state
	manifest = p_manifest
	if p_singleton == null:
		return _unavailable("GodotSteam (addons/godotsteam/) is not loaded")
	for method: String in METHODS:
		if not p_singleton.has_method(method):
			return _unavailable("this GodotSteam has no %s()" % method)
	for name: String in SIGNALS:
		if not p_singleton.has_signal(name):
			return _unavailable("this GodotSteam has no %s signal" % name)
	var result: Variant = p_singleton.call("steamInitEx", APP_ID, true)
	init_result = result if result is Dictionary else {}
	var status: Variant = init_result.get("status", -1)
	if not (status is int) or status != 0:
		return _unavailable("steamInitEx(%d) returned status %s (%s)" % [APP_ID, status, init_result.get("verbal", "")])
	singleton = p_singleton
	singleton.call("inputInit", false)
	var taken: Variant = singleton.call("setInputActionManifestFilePath", manifest)
	if not FileAccess.file_exists(manifest) or taken != true:
		push_warning("Steam Input: Steam did not take the action manifest %s; it falls back on the game's Steamworks settings" % manifest)
	singleton.connect("input_device_connected", _on_device_connected)
	singleton.connect("input_device_disconnected", _on_device_disconnected)
	singleton.connect("input_configuration_loaded", _on_configuration_loaded)
	singleton.call("enableDeviceCallbacks")
	state = WAITING
	print_verbose("Steam Input: Steam started (App ID %d), action manifest %s" % [APP_ID, manifest])
	return state


func state_name() -> String:
	return STATE_NAMES[state]


## Reads every controller of the session for one frame: see the class comment. racing picks the racing action set,
## else the menus set. Returns the number of pad events emitted. Nothing, and no call, unless Steam is the source.
##
## A switch of sets. Steam reports an action inactive while its set is not the controller's active one, which may last
## until Steam's next frame after activateActionSet(). So for SWITCH_FRAMES frames from the one where the set asked of
## a controller changes, a button that actions of the new set hold keeps its state while all of those actions read
## inactive: a Start held across the switch from the menus to a race stays one press instead of a second one that would
## pause the race. Otherwise an action that reads inactive is not held: after those frames (Steam still has not applied
## the set, or reports it inactive for another reason) its button goes up, and so does at once a button that no action
## of the set holds.
func frame(racing: bool) -> int:
	if state != ACTIVE:
		return 0
	var set_name := RACING if racing else MENUS
	var actions: Dictionary = ACTIONS[set_name]
	var events := 0
	for handle: int in announced:
		singleton.call("activateActionSet", handle, set_handles[set_name])
		if requested_set.get(handle, "") != set_name:
			requested_set[handle] = set_name
			switch_frames[handle] = SWITCH_FRAMES
		var switching: bool = switch_frames.get(handle, 0) > 0
		if switching:
			switch_frames[handle] -= 1
		var device: int = devices[handle]
		var down := 0
		var mapped := 0
		var read := 0
		for action: String in actions:
			var bit := 1 << int(actions[action])
			mapped |= bit
			var data: Variant = singleton.call("getDigitalActionData", handle, action_handles[action])
			if not (data is Dictionary) or (data as Dictionary).get("active", false) != true:
				continue
			read |= bit
			if (data as Dictionary).get("state", false) == true:
				down |= bit
		var kept := 0
		if switching:
			kept = held.get(device, 0) & mapped & ~read
		events += _hold(device, down | kept)
	return events


## True for a virtual device of one of Steam's controllers.
func owns(device: int) -> bool:
	return devices.values().has(device)


## A controller's GUID for the seats: its Steam handle, which it keeps when it comes back. "" for any other device.
func guid_of(device: int) -> String:
	var handle: Variant = devices.find_key(device)
	return "" if handle == null else "steam:%d" % handle


## True for a joypad event the game must not read: Godot's own pads once Steam is the session's source.
func drops(event: InputEvent) -> bool:
	if not (event is InputEventJoypadButton or event is InputEventJoypadMotion):
		return false
	return drops_device(event.device)


## True for a joypad device the game must not follow: one of Godot's own once Steam is the session's source.
func drops_device(device: int) -> bool:
	return state == ACTIVE and not owns(device)


# --- Steam's callbacks -----------------------------------------------------------------------------------------------


func _on_device_connected(handle: int) -> void:
	if not connected.has(handle):
		connected.append(handle)
	_announce(handle)


func _on_device_disconnected(handle: int) -> void:
	connected.erase(handle)
	if not announced.has(handle):
		return
	announced.erase(handle)
	requested_set.erase(handle)
	switch_frames.erase(handle)
	var device: int = devices[handle]
	_hold(device, 0)
	print_verbose("Steam Input: controller %d (pad %d) went away" % [handle, device])
	pad_connection.emit(device, false)


func _on_configuration_loaded(_app_id: int, handle: int, config: Dictionary) -> void:
	var unknown := _read_handles()
	print_verbose("Steam Input: configuration loaded for controller %d: %s, handles %s %s, no handle for %s" % [
		handle, config, set_handles, action_handles, unknown
	])
	if config.get("uses_steam_input_api", true) != true:
		return
	if not configured.has(handle):
		configured.append(handle)
	if not connected.has(handle):
		connected.append(handle)
	if state != WAITING:
		_announce(handle)
		return
	if not unknown.is_empty():
		if not warned_unknown:
			warned_unknown = true
			var names := ACTIONS.size()
			for set_name: String in ACTIONS:
				names += (ACTIONS[set_name] as Dictionary).size()
			push_warning("Steam Input: Steam has no handle for %s, so it has not loaded the game's action manifest (%s). %s" % [
				"any action set or action" if unknown.size() == names else ", ".join(unknown), manifest,
				"The game reads Godot's pads.",
			])
		return
	state = ACTIVE
	print_verbose("Steam Input: Steam's controllers are the game's pads for the rest of the session")
	took_over.emit()
	for each: int in connected:
		_announce(each)


# --- Inside ----------------------------------------------------------------------------------------------------------


func _unavailable(reason: String) -> int:
	state = UNAVAILABLE
	singleton = null
	push_warning("Steam Input is off: %s. The game reads Godot's pads." % reason)
	return state


## Reads the handles of the manifest's action sets and actions and returns the names Steam answered 0 for (it does not
## know them). Only a reading with none becomes set_handles and action_handles: Steam's handles name the game's sets and
## actions whatever the controller, so once read they stay, and a later reading with a 0 changes nothing.
func _read_handles() -> PackedStringArray:
	var sets := {}
	var actions := {}
	var unknown := PackedStringArray()
	for set_name: String in ACTIONS:
		sets[set_name] = int(singleton.call("getActionSetHandle", set_name))
		if sets[set_name] == 0:
			unknown.append(set_name)
	for set_name: String in ACTIONS:
		for action: String in ACTIONS[set_name]:
			actions[action] = int(singleton.call("getDigitalActionHandle", action))
			if actions[action] == 0:
				unknown.append(action)
	if unknown.is_empty():
		set_handles = sets
		action_handles = actions
	return unknown


## Gives a connected controller with the game's configuration its virtual pad, once Steam is the source.
func _announce(handle: int) -> void:
	if state != ACTIVE or announced.has(handle) or not connected.has(handle) or not configured.has(handle):
		return
	if not devices.has(handle):
		devices[handle] = DEVICE_BASE + devices.size()
	announced.append(handle)
	print_verbose("Steam Input: controller %d is pad %d (GUID %s)" % [handle, devices[handle], guid_of(devices[handle])])
	pad_connection.emit(devices[handle], true)


## Sets the buttons a virtual pad holds down, emitting an event for each change: buttons let go first, then the ones
## pressed, each in JoyButton order. Returns the number of events.
func _hold(device: int, buttons: int) -> int:
	var before: int = held.get(device, 0)
	held[device] = buttons
	var events := 0
	for pressed: bool in [false, true]:
		for button: int in JOY_BUTTON_SDL_MAX:
			var bit := 1 << button
			if (before & bit) != (buttons & bit) and ((buttons & bit) != 0) == pressed:
				var event := InputEventJoypadButton.new()
				event.device = device
				event.button_index = button as JoyButton
				event.pressed = pressed
				event.pressure = 1.0 if pressed else 0.0
				pad_event.emit(event)
				events += 1
	return events
