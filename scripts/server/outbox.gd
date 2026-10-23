extends RefCounted
## The game server's mailbox for the API (docs/SPEC_ONLINE.md §16.2: "los servidores guardan un buzón en disco y reintentan"): the
## result of a match (POST /matches/{id}/result) and its replay (POST /matches/{id}/replay) are written to a directory first
## (user://outbox), then sent, and the file is removed only once the API accepted it, so a crash, a restart or an API that is
## down loses nothing. Each item is tried again with a growing wait (RETRY_MS, doubling up to MAX_WAIT_MS) until it is accepted.
##
## - 2xx: accepted. 409: the API already settled this match with another report (or the same one): done, nothing more to send.
## - 404 and 400 are tried a few times (MAX_REJECTED) and then the file is moved to `failed/` for a person to read: they will not
##   change by waiting. Everything else (network failure, 5xx, 401 while the key is rotated, 429) is tried again.
##
## Files: MATCH.result.json (the body) and MATCH.replay (the replay bytes). Items found in the directory at start-up (a previous
## run's) are sent first.

const ApiClient := preload("res://scripts/net/api_client.gd")
const Result := preload("res://scripts/net/api_result.gd")

const DEFAULT_DIR := "user://outbox"
const RETRY_MS := 2000
const MAX_WAIT_MS := 120000
const MAX_REJECTED := 5
const REPLAY_FORMAT := "godot-replay-1"
const KIND_RESULT := "result"
const KIND_REPLAY := "replay"

var dir: String = DEFAULT_DIR
var api: ApiClient = null
## {"path", "match_id", "kind", "tries", "rejected", "due_ms", "busy"} of the items waiting, oldest first.
var items: Array[Dictionary] = []
var sent: int = 0
var abandoned: int = 0


func _init(p_api: ApiClient = null, p_dir: String = DEFAULT_DIR) -> void:
	api = p_api
	dir = p_dir
	DirAccess.make_dir_recursive_absolute(dir)
	DirAccess.make_dir_recursive_absolute(dir + "/failed")


## Loads what a previous run left in the directory.
func load_existing() -> void:
	items = []
	for file in DirAccess.get_files_at(dir):
		var parts := file.split(".")
		if parts.size() >= 2 and (parts[1] == KIND_RESULT or parts[1] == KIND_REPLAY):
			_add(dir + "/" + file, parts[0], parts[1])


## Stores a match's result body ({"players": [...], ...}) and queues it.
func put_result(match_id: String, body: Dictionary) -> void:
	var path := "%s/%s.result.json" % [dir, match_id]
	if _write(path, JSON.stringify(body).to_utf8_buffer()):
		_add(path, match_id, KIND_RESULT)


func put_replay(match_id: String, replay: PackedByteArray) -> void:
	var path := "%s/%s.replay" % [dir, match_id]
	if _write(path, replay):
		_add(path, match_id, KIND_REPLAY)


func pending() -> int:
	return items.size()


## Sends what is due. Once per frame; `now_ms` is any monotonic clock.
func update(now_ms: int) -> void:
	if api == null:
		return
	for item in items:
		if item["busy"] or now_ms < int(item["due_ms"]):
			continue
		item["busy"] = true
		item["tries"] = int(item["tries"]) + 1
		var bytes := FileAccess.get_file_as_bytes(item["path"])
		var match_id: String = item["match_id"]
		if item["kind"] == KIND_RESULT:
			api.request_bytes("POST", "matches/%s/result" % match_id, bytes, PackedStringArray(), _done.bind(item, now_ms), "application/json")
		else:
			api.request_bytes("POST", "matches/%s/replay" % match_id, bytes, PackedStringArray(["X-Replay-Format: " + REPLAY_FORMAT]), _done.bind(item, now_ms))


## How long the item waits after its `tries`-th failure.
static func wait_ms(tries: int) -> int:
	return mini(RETRY_MS << clampi(tries - 1, 0, 10), MAX_WAIT_MS)


func _done(r: Result, item: Dictionary, now_ms: int) -> void:
	item["busy"] = false
	if r.ok or r.status == 409:
		sent += 1
		_remove(item, false)
		return
	if r.status == 400 or r.status == 404:
		item["rejected"] = int(item["rejected"]) + 1
		if int(item["rejected"]) >= MAX_REJECTED:
			abandoned += 1
			_remove(item, true)
			return
	item["due_ms"] = now_ms + wait_ms(int(item["tries"]))


func _add(path: String, match_id: String, kind: String) -> void:
	for item in items:
		if item["path"] == path:
			item["tries"] = 0
			item["due_ms"] = 0
			return
	items.append({"path": path, "match_id": match_id, "kind": kind, "tries": 0, "rejected": 0, "due_ms": 0, "busy": false})


func _remove(item: Dictionary, to_failed: bool) -> void:
	items.erase(item)
	var path: String = item["path"]
	if to_failed:
		DirAccess.rename_absolute(path, "%s/failed/%s" % [dir, path.get_file()])
	else:
		DirAccess.remove_absolute(path)


func _write(path: String, bytes: PackedByteArray) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_buffer(bytes)
	file.close()
	return true


## The body of POST /matches/{id}/result for a Room.result(): the places and abandons of the people who sat down with an API
## ticket (the API takes nothing else from a server). {} when there is nobody to report (a private room, development tickets).
static func result_body(result: Dictionary) -> Dictionary:
	if bool(result.get("private", false)):
		return {}
	var players: Array = []
	for row: Dictionary in result.get("seats", []):
		if bool(row.get("bot", true)) or str(row.get("player_id", "")).is_empty():
			continue
		players.append({"player_id": str(row["player_id"]), "place": int(row["place"]), "abandoned": bool(row["abandoned"])})
	if players.is_empty():
		return {}
	return {"players": players, "final_checksum": str(result.get("final_checksum", ""))}
