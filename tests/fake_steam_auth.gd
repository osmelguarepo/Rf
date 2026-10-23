extends "res://scripts/net/steam_auth.gd"
## A SteamAuth that answers by itself, for the login tests; not a test file. `running` is whether Steam is there; `answer` is what
## poll() gives once begin() was called (set it before, or later); `begun` counts begin() calls.

var running: bool = true
var answer: Dictionary = {"ok": true, "ticket": "deadbeef", "steam_id": "76561198000000001"}
var begun: int = 0
var _asked: bool = false


func available() -> bool:
	return running


func begin(_now_ms: int = 0) -> bool:
	if not running:
		return false
	begun += 1
	_asked = true
	return true


func poll(_now_ms: int = 0) -> Dictionary:
	if not _asked or answer.is_empty():
		return {}
	_asked = false
	return answer
