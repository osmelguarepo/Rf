extends SceneTree
## A headless client that goes through the REAL online path against a real API and game server (tools/e2e_online.sh): guest or
## Steam-stand-in login (ApiClient, LoginFlow), the queue (Matchmaking: latency probes, POST /queue, status, ready check, join),
## the WebSocket (OnlineSession over WsTransport) with the API's own ticket, and a simple driver for the whole match.
##
##   godot --headless --path . -s res://tools/net_queue_client.gd -- --api=http://127.0.0.1:8080 [OPTION...]
##
## Options (defaults in brackets): --api=URL [http://127.0.0.1:8080], --label=TEXT [client], --steam=ID (log in as that SteamID with
## the API's development verifier, DEV_FAKE_STEAM=1 on the API; without it a guest), --xff=IP (X-Forwarded-For, for an API with
## TRUST_PROXY=1: ranked matches need distinct /24s), --max-seconds=N [420], --abandon-after=N (seconds of play after which this
## client drops the connection and calls POST /match/{id}/leave), --cancel-after=N (leave the queue after N seconds and exit).
## Output lines start with "qclient LABEL:"; the end line has "confirmed checksum HEX", "match ID", "points N".

const ApiClient := preload("res://scripts/net/api_client.gd")
const Result := preload("res://scripts/net/api_result.gd")
const Account := preload("res://scripts/net/account.gd")
const LoginFlow := preload("res://scripts/net/login_flow.gd")
const Matchmaking := preload("res://scripts/net/matchmaking.gd")
const HttpRequestTransport := preload("res://scripts/net/http_request_transport.gd")
const OnlineSession := preload("res://scripts/net/online_session.gd")
const WsTransport := preload("res://scripts/net/ws_transport.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")
const Rollback := preload("res://scripts/net/rollback.gd")

var label: String = "client"
var api: ApiClient
var account := Account.new()
var login: LoginFlow
var mm: Matchmaking
var session: OnlineSession = null
var _started_ms: int = 0
var _max_ms: int = 420000
var _abandon_after_ms: int = -1
var _cancel_after_ms: int = -1
var _play_started_ms: int = -1
var _queued_at_ms: int = 0
var _done_at_ms: int = -1
var _rng := RandomNumberGenerator.new()
var _steer: int = 0
var _frame: int = 0
var _phase: int = 0
var _last_mm_state: int = -1
var _match_id: String = ""
var _points_after: int = -1
var _steam: String = ""


func _initialize() -> void:
	label = _arg("label", "client")
	_rng.seed = hash(label)
	_max_ms = int(_arg("max-seconds", "420")) * 1000
	if _arg("abandon-after", "") != "":
		_abandon_after_ms = int(_arg("abandon-after", "0")) * 1000
	if _arg("cancel-after", "") != "":
		_cancel_after_ms = int(_arg("cancel-after", "0")) * 1000
	_steam = _arg("steam", "")
	api = ApiClient.new(HttpRequestTransport.new(root), _arg("api", "http://127.0.0.1:8080"))
	if _arg("xff", "") != "":
		api.extra_headers = PackedStringArray(["X-Forwarded-For: " + _arg("xff", "")])
	login = LoginFlow.new(api, account)
	mm = Matchmaking.new(api)
	_started_ms = Time.get_ticks_msec()


func _begin_login() -> void:
	# Not in _initialize: the root window is not in the tree yet and HTTPRequest nodes cannot be added.
	_phase = 0
	if _steam.is_empty():
		login.start_guest()
	else:
		api.request("POST", "auth/steam", {"ticket": "ok-" + _steam}, login._on_session)
		login.state = LoginFlow.State.REQUESTING


func _process(_delta: float) -> bool:
	var now := Time.get_ticks_msec()
	_frame += 1
	api.poll()
	if now - _started_ms > _max_ms:
		_fail("timeout in phase %d (queue state %d)" % [_phase, mm.state])
		return false
	if _frame == 1:
		_begin_login()
	match _phase:
		0:
			_logging_in()
		1:
			_queueing(now)
		2:
			_playing(now)
		3:
			_finishing(now)
	return false


func _logging_in() -> void:
	if login.state == LoginFlow.State.FAILED:
		_fail("login failed: %s %s" % [login.error, login.message])
	elif login.state == LoginFlow.State.DONE:
		print("qclient %s: logged in as %s (player %s, %s)" % [label, account.player_name, account.player_id, "guest" if account.guest else "steam"])
		mm.find_race()
		_queued_at_ms = Time.get_ticks_msec()
		_phase = 1


func _queueing(now: int) -> void:
	mm.update(now)
	if mm.state != _last_mm_state:
		_last_mm_state = mm.state
		print("qclient %s: queue state %d after %.1f s (found %d, band %d, match %s)" % [label, mm.state, (now - _queued_at_ms) / 1000.0, mm.players_found, mm.band_divisions, mm.match_id])
	if mm.state == Matchmaking.State.FOUND:
		mm.accept()
	elif mm.state == Matchmaking.State.FAILED:
		_fail("queue failed: %s (%s) penalty %d" % [mm.error, mm.message, mm.penalty_s])
	elif mm.state == Matchmaking.State.IDLE and not mm.message.is_empty():
		_fail("queue ended: " + mm.message)
	elif _cancel_after_ms >= 0 and now - _queued_at_ms > _cancel_after_ms:
		mm.cancel()
		print("qclient %s: left the queue" % label)
		_phase = 3
		_done_at_ms = now
	elif mm.state == Matchmaking.State.JOINED:
		_match_id = mm.match_id
		print("qclient %s: joined match %s at %s after %.1f s in the queue" % [label, _match_id, mm.join["ws_url"], (now - _queued_at_ms) / 1000.0])
		session = OnlineSession.new()
		var error := session.connect_to(WsTransport.new(), mm.join["ws_url"], mm.join["ticket"])
		if error != OK:
			_fail("cannot connect (error %d)" % error)
			return
		_phase = 2


func _playing(now: int) -> void:
	if _frame % 40 == 0:
		_steer = _rng.randi_range(-1, 1)
	session.update(now, PlayerInput.encode(true, false, _steer, true))
	if session.state == OnlineSession.State.PLAYING and _play_started_ms < 0:
		_play_started_ms = now
		print("qclient %s: playing" % label)
	if session.state == OnlineSession.State.REJECTED:
		_fail("rejected: " + session.reject_reason)
	elif session.state == OnlineSession.State.FAILED:
		_fail("failed: " + session.failure)
	elif _abandon_after_ms >= 0 and _play_started_ms >= 0 and now - _play_started_ms > _abandon_after_ms:
		print("qclient %s: abandoning the match" % label)
		session.close()
		mm.leave_match()
		_phase = 3
		_done_at_ms = now
		_cancel_after_ms = -2
	elif session.state == OnlineSession.State.ENDED:
		_phase = 3
		_done_at_ms = now
		_report()


func _finishing(now: int) -> void:
	api.poll()
	if _cancel_after_ms == -2 or _cancel_after_ms >= 0:
		# Leave calls are fire and forget: give them a moment to reach the API.
		if now - _done_at_ms > 1500:
			quit(0)
		return
	if _points_after < 0 and now - _done_at_ms > 1000:
		# The server reports the result a moment after the clients see the end; the points are read a bit later.
		_points_after = -2
		create_timer(4.0).timeout.connect(func() -> void:
			api.request("GET", "me", null, func(r: Result) -> void:
				var body := r.dict()
				print("qclient %s: final profile points %d ranked_matches %d division %s" % [label, int(body.get("points", -1)), int(body.get("ranked_matches", -1)), str(body.get("division_name", "?"))])
				quit(0)))


func _report() -> void:
	var rb: Rollback = session.rollback
	var places: Array = session.end_info.get("places", [])
	var points: Array = session.end_info.get("points", [])
	print("qclient %s: ended. match %s, places %s, points %s, rollbacks %d, resyncs %d, desyncs %d, checksums ok %d, confirmed checksum %s" % [
		label, _match_id, str(places), str(points), rb.rebuilds, session.resyncs, session.desyncs, session.checksums_ok,
		session.confirmed_match().checksum(),
	])


func _fail(why: String) -> void:
	printerr("qclient %s: FAILED: %s" % [label, why])
	quit(1)


static func _arg(name: String, fallback: String) -> String:
	var prefix := "--%s=" % name
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with(prefix):
			return argument.trim_prefix(prefix)
	return fallback
