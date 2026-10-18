extends RefCounted
## A stand-in for GodotSteam's engine singleton (B4), for the tests of scripts/input/steam_input.gd; not a test file.
## It has the methods the adapter calls, with GodotSteam 4.23.1's names and arguments, and records every call in
## order; and the three Steam Input signals, which a test emits as Steam would. What Steam answers is set here:
## steamInitEx()'s result, the handles of action sets and actions (0, as Steam before a configuration has loaded, unless
## named), and the digital actions each controller holds down.

signal input_device_connected(input_handle: int)
signal input_device_disconnected(input_handle: int)
signal input_configuration_loaded(app_id: int, device_handle: int, config_data: Dictionary)

## [method, [arguments]] for each call, oldest first.
var calls: Array = []
## What steamInitEx() returns.
var init_result: Dictionary = {"status": 0, "verbal": "OK"}
## What setInputActionManifestFilePath() returns.
var manifest_taken: bool = true
## Action set name -> handle, action name -> handle.
var set_handles: Dictionary = {}
var action_handles: Dictionary = {}
## Controller handle -> the action handles it holds down (true).
var down: Dictionary = {}
## Controller handle -> the action set handle activated last.
var active_set: Dictionary = {}
## How many of the three signals had a connection when enableDeviceCallbacks() was called (-1: not called).
var connected_at_enable: int = -1


## Handles for the action sets and actions given: 1, 2, ... in order, the same name always the same handle.
func name_handles(sets: Array, actions: Array) -> void:
	var next := 1
	for name: String in sets:
		set_handles[name] = next
		next += 1
	for name: String in actions:
		if not action_handles.has(name):
			action_handles[name] = next
			next += 1


## Holds an action down on a controller, or lets go of it.
func hold(handle: int, action: String, pressed: bool = true) -> void:
	var actions: Dictionary = down.get(handle, {})
	actions[action_handles[action]] = pressed
	down[handle] = actions


func let_go(handle: int) -> void:
	down.erase(handle)


## The names of the methods called, oldest first.
func names() -> Array:
	var out: Array = []
	for entry: Array in calls:
		out.append(entry[0])
	return out


## The arguments of each call of one method, oldest first.
func calls_of(method: String) -> Array:
	var out: Array = []
	for entry: Array in calls:
		if entry[0] == method:
			out.append(entry[1])
	return out


func forget_calls() -> void:
	calls = []


# --- GodotSteam's methods ----------------------------------------------------------------------------------------------


func steamInitEx(app_id: int, embed_callbacks: bool) -> Dictionary:
	calls.append(["steamInitEx", [app_id, embed_callbacks]])
	return init_result


func inputInit(explicitly_call_runframe: bool) -> bool:
	calls.append(["inputInit", [explicitly_call_runframe]])
	return true


func setInputActionManifestFilePath(manifest_path: String) -> bool:
	calls.append(["setInputActionManifestFilePath", [manifest_path]])
	return manifest_taken


func enableDeviceCallbacks() -> void:
	calls.append(["enableDeviceCallbacks", []])
	connected_at_enable = 0
	for name: String in ["input_device_connected", "input_device_disconnected", "input_configuration_loaded"]:
		if not get_signal_connection_list(name).is_empty():
			connected_at_enable += 1


func getActionSetHandle(action_set_name: String) -> int:
	calls.append(["getActionSetHandle", [action_set_name]])
	return set_handles.get(action_set_name, 0)


func getDigitalActionHandle(action_name: String) -> int:
	calls.append(["getDigitalActionHandle", [action_name]])
	return action_handles.get(action_name, 0)


func activateActionSet(input_handle: int, action_set_handle: int) -> void:
	calls.append(["activateActionSet", [input_handle, action_set_handle]])
	active_set[input_handle] = action_set_handle


func getDigitalActionData(input_handle: int, digital_action_handle: int) -> Dictionary:
	calls.append(["getDigitalActionData", [input_handle, digital_action_handle]])
	var actions: Dictionary = down.get(input_handle, {})
	return {"state": actions.get(digital_action_handle, false), "active": true}
