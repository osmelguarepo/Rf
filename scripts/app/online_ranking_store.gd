extends "res://scripts/app/ranking_store.gd"
## The online leaderboard (docs/SPEC_ONLINE.md §9, §16.3), with the interface of RankingStore (record, apply, top) so the RANKING
## screen can show either: this one reads the API's GET /leaderboard?limit= (refresh(), asynchronous: top() answers from what the
## last refresh brought) and GET /me for the player's own record. A client never writes the ranking: the game server's result
## is what changes it, so apply() changes nothing and reports no change.
##
## A record is {id, name, points, matches}, with the player's id as text (ids do not fit a double).

const ApiClient := preload("res://scripts/net/api_client.gd")
const Result := preload("res://scripts/net/api_result.gd")

var api: ApiClient
var loaded: bool = false
var failed: bool = false
var error: String = ""
var _entries: Array[Dictionary] = []
var _me: Dictionary = {}


func _init(p_api: ApiClient = null) -> void:
	api = p_api


## Asks for the best `limit` players (1 to 100); `done` (optional) is called when the answer is in.
func refresh(limit: int, done: Callable = Callable()) -> void:
	loaded = false
	failed = false
	api.request("GET", "leaderboard?limit=%d" % clampi(limit, 1, 100), null, func(r: Result) -> void:
		if r.ok:
			_entries = entries_of(r.dict().get("entries", []))
			loaded = true
		else:
			failed = true
			error = r.error
		if done.is_valid():
			done.call(r))


## The player's own profile (as GET /me answers), kept for record().
func set_me(profile: Dictionary) -> void:
	_me = profile


## Leaderboard rows from the API's entries ({rank, player_id, name, points, division, division_name}).
static func entries_of(rows: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not (rows is Array):
		return out
	for row: Variant in rows:
		if row is Dictionary:
			out.append({
				"id": str(row.get("player_id", "")), "name": str(row.get("name", "")), "points": int(row.get("points", 0)),
				"matches": int(row.get("ranked_matches", 0)), "rank": int(row.get("rank", 0)),
			})
	return out


func record(id: String) -> Dictionary:
	if not _me.is_empty() and str(_me.get("player_id", "")) == id:
		return {"id": id, "name": str(_me.get("name", id)), "points": int(_me.get("points", 0)), "matches": int(_me.get("ranked_matches", 0))}
	for entry in _entries:
		if entry["id"] == id:
			return entry.duplicate()
	return {"id": id, "name": id, "points": 0, "matches": 0}


## The server settles online matches: nothing to apply here.
func apply(id: String, _player_name: String, _change: int) -> Dictionary:
	var points: int = record(id)["points"]
	return {"before": points, "after": points, "delta": 0}


func top(n: int) -> Array[Dictionary]:
	var best: Array[Dictionary] = []
	best.append_array(_entries.slice(0, n))
	return best
