extends RefCounted
## The Steam side of logging in on the desktop (docs/SPEC_ONLINE.md §4): a web-API auth ticket for the identity "fuelrivals",
## which the API checks with Steam (POST /auth/steam). Like steam_input.gd it never names GodotSteam's class: the engine singleton
## comes from `lookup` (the app gives the one Steam Input started, or null) and every call goes through call(). A test gives a
## subclass that answers by itself. No signals for the app: begin(), then poll() each frame until it answers.
##
## poll() returns {} while waiting, then {"ok": true, "ticket": HEX, "steam_id": TEXT} or {"ok": false, "error": TEXT}.

const IDENTITY := "fuelrivals"
const SIGNAL_NAME := "get_ticket_for_web_api"
const REQUIRED: PackedStringArray = ["getAuthTicketForWebApi", "getSteamID"]
## Seconds to wait for Steam's answer.
const TIMEOUT_MS := 10000

## Returns the Steam singleton, or null while Steam is not running.
var lookup: Callable = Callable()
var _result: Dictionary = {}
var _pending: bool = false
var _since_ms: int = 0
var _handle: int = 0


func available() -> bool:
	var steam := _singleton()
	if steam == null:
		return false
	for name in REQUIRED:
		if not steam.has_method(name):
			return false
	return true


## Asks Steam for a ticket. False when Steam cannot be used.
func begin(now_ms: int = 0) -> bool:
	var steam := _singleton()
	if steam == null or not available():
		return false
	_result = {}
	_pending = true
	_since_ms = now_ms
	if not steam.is_connected(SIGNAL_NAME, _on_ticket):
		steam.connect(SIGNAL_NAME, _on_ticket)
	_handle = int(steam.call("getAuthTicketForWebApi", IDENTITY))
	return true


func poll(now_ms: int = 0) -> Dictionary:
	if _pending and now_ms - _since_ms > TIMEOUT_MS and _since_ms > 0:
		_pending = false
		_result = {"ok": false, "error": "STEAM DID NOT ANSWER"}
	if _result.is_empty():
		return {}
	var out := _result
	_result = {}
	_pending = false
	return out


## Steam's ticket as the API wants it: lower-case hex.
static func hex_of(buffer: Array) -> String:
	var bytes := PackedByteArray()
	for b: Variant in buffer:
		bytes.append(int(b) & 0xFF)
	return bytes.hex_encode()


func _on_ticket(auth_ticket: int, result: int, _size: int, buffer: Array) -> void:
	if not _pending or (_handle != 0 and auth_ticket != _handle):
		return
	var steam := _singleton()
	if result != 1 or buffer.is_empty() or steam == null:
		_result = {"ok": false, "error": "STEAM REFUSED THE TICKET"}
		return
	_result = {"ok": true, "ticket": hex_of(buffer), "steam_id": str(steam.call("getSteamID"))}


func _singleton() -> Object:
	if not lookup.is_valid():
		return null
	return lookup.call()
