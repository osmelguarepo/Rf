extends RefCounted
## The player's side of the queue (docs/SPEC_ONLINE.md §7, §16.4; the contract of the API's matchmaker), a state machine over the
## ApiClient that the queue screen reads and tests drive with a fake transport:
##
##   IDLE -> MEASURING (a few GETs to each region's /healthz for its latency) -> JOINING (POST /queue {latencies})
##        -> WAITING (GET /queue/status each second: wait_s, band_divisions, players_found)
##        -> FOUND (a match is ready: the player has until `ready_deadline` to accept: POST /queue/ready {match_id})
##        -> READY (accepted; waiting for the others) -> STARTING (GET /match/{id}/join) -> JOINED (ws_url and ticket in `join`)
## FAILED carries `message` (and `penalty_s` when the API turned the player away for leaving matches). cancel() leaves the
## queue (DELETE /queue) or the match (POST /match/{id}/leave). A status that falls back to idle or waiting while a match was
## found means the match fell through: the screen is told by `message`. Every callback of a call made before cancel() or a new
## find_race() is ignored (`_generation`), so a late answer cannot revive a queue the player left.
##
## `regions` maps a region name to the base URL its /healthz is read from ("" is the API itself): one region for now.

const ApiClient := preload("res://scripts/net/api_client.gd")
const Result := preload("res://scripts/net/api_result.gd")

enum State { IDLE, MEASURING, JOINING, WAITING, FOUND, READY, STARTING, JOINED, FAILED }

const STATUS_EVERY_MS := 1000
const PROBES := 3
const MAX_NETWORK_FAILS := 4
const MAX_JOIN_TRIES := 4
const DEFAULT_REGION := "default"

var api: ApiClient
var regions: Dictionary = {DEFAULT_REGION: ""}
var state: State = State.IDLE
var message: String = ""
var error: String = ""
var penalty_s: int = 0
var wait_s: int = 0
var band_divisions: int = 0
var players_found: int = 0
var match_id: String = ""
var ready_deadline: int = 0
var accepted: bool = false
## {"ws_url": String, "ticket": String} once JOINED.
var join: Dictionary = {}
var latencies: Dictionary = {}
## Milliseconds and Unix seconds: the app's clocks, or a test's.
var clock: Callable = Callable()
var unix_clock: Callable = Callable()

var _generation: int = 0
var _next_status_ms: int = 0
var _status_inflight: bool = false
var _network_fails: int = 0
var _join_tries: int = 0
var _next_join_ms: int = 0
var _probes_left: Dictionary = {}
var _probe_best: Dictionary = {}


func _init(p_api: ApiClient) -> void:
	api = p_api


func active() -> bool:
	return state in [State.MEASURING, State.JOINING, State.WAITING, State.FOUND, State.READY, State.STARTING]


## Starts looking for a race.
func find_race() -> void:
	if active() or state == State.JOINED:
		return
	_generation += 1
	_reset()
	state = State.MEASURING
	_probes_left = {}
	_probe_best = {}
	latencies = {}
	for region: String in regions:
		_probes_left[region] = PROBES
	for region: String in regions:
		_probe(region, _generation)


## Seconds left to accept the found match.
func countdown_s() -> int:
	return maxi(ready_deadline - _unix_now(), 0)


## The player accepts the found match.
func accept() -> void:
	if state != State.FOUND or match_id.is_empty():
		return
	var gen := _generation
	api.request("POST", "queue/ready", {"match_id": match_id}, func(r: Result) -> void:
		if gen != _generation:
			return
		if r.ok:
			accepted = true
			if state == State.FOUND:
				state = State.READY
		else:
			_request_failed(r, "COULD NOT ACCEPT"))


## Leaves the queue, or the match when the connection is already on its way.
func cancel() -> void:
	var was := state
	_generation += 1
	if was in [State.JOINING, State.WAITING, State.FOUND, State.READY, State.STARTING]:
		api.request("DELETE", "queue", null, func(_r: Result) -> void: pass)
	elif was == State.JOINED:
		leave_match()
	_reset()
	state = State.IDLE


## Tells the API the player leaves a match (after the connection started; the API counts the abandon).
func leave_match() -> void:
	if not match_id.is_empty():
		api.request("POST", "match/%s/leave" % match_id, {}, func(_r: Result) -> void: pass)


## Once per frame.
func update(now_ms: int) -> void:
	if state == State.STARTING and join.is_empty():
		if now_ms >= _next_join_ms and not _status_inflight:
			_fetch_join(now_ms)
		return
	if state in [State.WAITING, State.FOUND, State.READY] and not _status_inflight and now_ms >= _next_status_ms:
		_next_status_ms = now_ms + STATUS_EVERY_MS
		_status_inflight = true
		var gen := _generation
		api.request("GET", "queue/status", null, func(r: Result) -> void:
			if gen != _generation:
				return
			_status_inflight = false
			_on_status(r))


# --- Latency ---------------------------------------------------------------------------------------------------------------


func _probe(region: String, gen: int) -> void:
	var base: String = regions[region]
	var url := ApiClient.join_url(base if not base.is_empty() else api.base_url, "healthz")
	var started := _now()
	api.request_url("GET", url, null, _on_probe.bind(region, gen, started), false)


func _on_probe(r: Result, region: String, gen: int, started: int) -> void:
	if gen != _generation:
		return
	var left := int(_probes_left[region]) - 1
	if r.ok:
		var ms := maxi(_now() - started, 1)
		_probe_best[region] = mini(int(_probe_best.get(region, ms)), ms)
	if r.ok and left > 0:
		_probes_left[region] = left
		_probe(region, gen)
	else:
		_probes_left[region] = 0
		_probes_done(gen)


func _probes_done(gen: int) -> void:
	for region: String in _probes_left:
		if int(_probes_left[region]) > 0:
			return
	if _probe_best.is_empty():
		_fail("network", "ONLINE UNAVAILABLE")
		return
	latencies = _probe_best.duplicate()
	state = State.JOINING
	api.request("POST", "queue", {"latencies": latencies}, func(r: Result) -> void:
		if gen != _generation:
			return
		if r.ok or r.status == 409:
			state = State.WAITING
			_next_status_ms = 0
		else:
			_request_failed(r, "COULD NOT JOIN THE QUEUE"))


# --- Status ----------------------------------------------------------------------------------------------------------------


func _on_status(r: Result) -> void:
	if not r.ok:
		if r.network:
			_network_fails += 1
			if _network_fails >= MAX_NETWORK_FAILS:
				_fail("network", "ONLINE UNAVAILABLE")
			return
		_request_failed(r, "QUEUE ERROR")
		return
	_network_fails = 0
	var body := r.dict()
	wait_s = int(body.get("wait_s", wait_s))
	band_divisions = int(body.get("band_divisions", band_divisions))
	players_found = int(body.get("players_found", players_found))
	var server_state := str(body.get("state", "idle"))
	var matched: Variant = body.get("match")
	if matched is Dictionary:
		match_id = str((matched as Dictionary).get("match_id", match_id))
		ready_deadline = int((matched as Dictionary).get("ready_deadline_unix", ready_deadline))
	match server_state:
		"waiting":
			if state in [State.FOUND, State.READY]:
				message = "MATCH FELL THROUGH - SEARCHING AGAIN"
				accepted = false
			state = State.WAITING
		"found":
			state = State.READY if accepted else State.FOUND
		"ready":
			accepted = true
			state = State.READY
		"starting":
			if state != State.STARTING:
				state = State.STARTING
				_join_tries = 0
				_next_join_ms = 0
		_:
			var was := state
			_reset()
			state = State.IDLE
			message = "MATCH CANCELLED" if was in [State.FOUND, State.READY, State.STARTING] else "LEFT THE QUEUE"


func _fetch_join(now_ms: int) -> void:
	_status_inflight = true
	_join_tries += 1
	var gen := _generation
	api.request("GET", "match/%s/join" % match_id, null, func(r: Result) -> void:
		if gen != _generation:
			return
		_status_inflight = false
		if r.ok:
			var body := r.dict()
			var url := str(body.get("ws_url", ""))
			var ticket := str(body.get("ticket", ""))
			if url.is_empty() or ticket.is_empty():
				_fail("bad_response", "THE SERVER SENT NO MATCH")
				return
			join = {"ws_url": url, "ticket": ticket}
			state = State.JOINED
		elif _join_tries < MAX_JOIN_TRIES and (r.network or r.status >= 500):
			_next_join_ms = now_ms + STATUS_EVERY_MS
		else:
			_request_failed(r, "COULD NOT JOIN THE MATCH"))


# --- Failures --------------------------------------------------------------------------------------------------------------


## An API error in the middle of the queue: a refused session, a penalty (HTTP 429 or an error that names one) or a plain failure.
func _request_failed(r: Result, fallback: String) -> void:
	if r.status == 401:
		_fail("session_expired", "SESSION ENDED - LOG IN AGAIN")
	elif r.status == 429 or r.error.contains("penal") or r.error == "queue_banned":
		penalty_s = r.retry_after_s
		_fail(r.error, penalty_text(r.retry_after_s))
	elif r.network:
		_fail("network", "ONLINE UNAVAILABLE")
	else:
		_fail(r.error, r.message.to_upper() if not r.message.is_empty() and r.message.length() <= 40 else fallback)


## "YOU LEFT TOO MANY MATCHES - WAIT 2 MIN" for a penalty of `seconds`.
static func penalty_text(seconds: int) -> String:
	if seconds <= 0:
		return "YOU LEFT TOO MANY MATCHES - WAIT A WHILE"
	if seconds >= 120:
		return "YOU LEFT TOO MANY MATCHES - WAIT %d MIN" % ceili(seconds / 60.0)
	return "YOU LEFT TOO MANY MATCHES - WAIT %d S" % seconds


func _fail(code: String, text: String) -> void:
	state = State.FAILED
	error = code
	message = text
	_generation += 1


func _reset() -> void:
	message = ""
	error = ""
	penalty_s = 0
	wait_s = 0
	band_divisions = 0
	players_found = 0
	match_id = ""
	ready_deadline = 0
	accepted = false
	join = {}
	_network_fails = 0
	_status_inflight = false


func _now() -> int:
	return clock.call() if clock.is_valid() else Time.get_ticks_msec()


func _unix_now() -> int:
	return unix_clock.call() if unix_clock.is_valid() else int(Time.get_unix_time_from_system())
