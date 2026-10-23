extends RefCounted
## Where ranking totals live (docs/SPEC_RANKING.md §10). This is the in-memory store LOCAL uses: it keeps the totals for
## the session and forgets them when the game closes. ONLINE will have a store of its own, with the same calls, that
## keeps them in a database; the result of an online match is then written by the server, never by a client.
##
## A record is {id, name, points, matches}.

const Ranking := preload("res://scripts/sim/ranking.gd")

var _records: Dictionary = {}


## The record of a player; a new player starts at 0 points.
func record(id: String) -> Dictionary:
	if not _records.has(id):
		return {"id": id, "name": id, "points": 0, "matches": 0}
	return (_records[id] as Dictionary).duplicate()


## Applies a match's change to a player's total (never below 0) and returns {before, after, delta}: the totals as they
## were and are, and the change actually applied.
func apply(id: String, player_name: String, change: int) -> Dictionary:
	var current := record(id)
	var before: int = current["points"]
	var after := Ranking.apply(before, change)
	current["name"] = player_name
	current["points"] = after
	current["matches"] = int(current["matches"]) + 1
	_records[id] = current
	return {"before": before, "after": after, "delta": after - before}


## The best n records, most points first (the earlier player on a tie).
func top(n: int) -> Array[Dictionary]:
	var all: Array[Dictionary] = []
	for id: String in _records:
		all.append((_records[id] as Dictionary).duplicate())
	all.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["points"] != b["points"]:
			return a["points"] > b["points"]
		return str(a["id"]) < str(b["id"]))
	var best: Array[Dictionary] = []
	best.append_array(all.slice(0, n))
	return best
