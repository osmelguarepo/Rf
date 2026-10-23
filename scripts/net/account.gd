extends RefCounted
## Who is logged in (docs/SPEC_ONLINE.md §4, §16.3): the profile the API answered with (POST /auth/*, GET /me). Ids are text.
## The session token lives in the ApiClient, in memory only; this holds what the screens show.

var player_id: String = ""
var steam_id: String = ""
var player_name: String = ""
var guest: bool = false
## False for guests: they play without points.
var ranked: bool = false
var points: int = 0
var division: int = 0
var division_name: String = ""
var points_to_next: int = 0
var rank: int = 0
var provisional: bool = false
var matches: int = 0
var logged_in: bool = false


## Takes the API's profile object ({player_id, steam_id, name, guest, ranked, points, division, ...}).
func set_profile(profile: Dictionary) -> void:
	player_id = str(profile.get("player_id", player_id))
	steam_id = str(profile.get("steam_id", ""))
	player_name = str(profile.get("name", player_name))
	guest = bool(profile.get("guest", false))
	ranked = bool(profile.get("ranked", false))
	points = int(profile.get("points", 0))
	division = int(profile.get("division", 0))
	division_name = str(profile.get("division_name", ""))
	points_to_next = int(profile.get("points_to_next", 0))
	rank = int(profile.get("rank", 0))
	provisional = bool(profile.get("provisional", false))
	matches = int(profile.get("ranked_matches", 0))
	logged_in = true


func clear() -> void:
	set_profile({})
	player_id = ""
	player_name = ""
	logged_in = false


## One line for a screen: "NAME  GOLD  730" (a guest: "NAME  GUEST  NO POINTS").
func summary() -> String:
	if guest or not ranked:
		return "%s  GUEST  NO POINTS" % player_name
	return "%s  %s  %d" % [player_name, division_name, points]
