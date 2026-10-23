extends SceneTree
## A headless client of a game server, for trying the real thing on one machine (tools/net_local.sh starts a server and two of
## these): it connects over a WebSocket with a ticket, plays the match with a simple driver, and prints how it went.
##
##   godot --headless --path . -s res://tools/net_client.gd -- --server=ws://127.0.0.1:9080 --seat=0 [OPTION...]
##
## Options (defaults in brackets): --server=URL [ws://127.0.0.1:9080], --match=ID [local], --seat=N [0], --seats=N [6],
## --humans=MASK of the seats that are people [3], --seed=N [5], --steam=ID [76561198000000000 + seat], --max-seconds=N [180].
## A private room instead of a ticket: --create (make a room, printing its code) or --join=CODE, with --name=TEXT; --start makes
## the owner start the room once --people=N [2] have joined. The ticket is a dev ticket: the server must run with --dev.
## It prints one line "client SEAT: ended ..." at the end, with the checksum of the confirmed state, which must be the same
## on every client of the match.

const OnlineSession := preload("res://scripts/net/online_session.gd")
const WsTransport := preload("res://scripts/net/ws_transport.gd")
const Ticket := preload("res://scripts/net/ticket.gd")
const RoomCode := preload("res://scripts/net/room_code.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")
const Rollback := preload("res://scripts/net/rollback.gd")

var session := OnlineSession.new()
var seat: int = 0
var _started_ms: int = 0
var _max_ms: int = 180000
var _done_at_ms: int = -1
var _start_room: bool = false
var _people: int = 2
var _sent_start: bool = false
var _rng := RandomNumberGenerator.new()
var _steer: int = 0
var _frame: int = 0
var _printed_code: bool = false


func _initialize() -> void:
	seat = int(_arg("seat", "0"))
	_rng.seed = 100 + seat
	_max_ms = int(_arg("max-seconds", "180")) * 1000
	_start_room = OS.get_cmdline_user_args().has("--start")
	_people = int(_arg("people", "2"))
	var ticket: String
	if OS.get_cmdline_user_args().has("--create"):
		ticket = RoomCode.new_ticket(_arg("name", "CLIENT%d" % seat))
	elif _arg("join", "") != "":
		ticket = RoomCode.join_ticket(_arg("join", ""), _arg("name", "CLIENT%d" % seat))
	else:
		var steam := _arg("steam", str(76561198000000000 + seat))
		ticket = Ticket.issue_dev(_arg("match", "local"), seat, steam, int(_arg("seed", "5")), int(_arg("seats", "6")), int(_arg("humans", "3")))
	_started_ms = Time.get_ticks_msec()
	var error := session.connect_to(WsTransport.new(), _arg("server", "ws://127.0.0.1:9080"), ticket)
	if error != OK:
		printerr("client %d: cannot start connecting (error %d)" % [seat, error])
		quit(2)


func _process(_delta: float) -> bool:
	var now := Time.get_ticks_msec()
	_frame += 1
	if _frame % 40 == 0:
		_steer = _rng.randi_range(-1, 1)
	session.update(now, PlayerInput.encode(true, false, _steer, true))
	if session.state == OnlineSession.State.LOBBY:
		_lobby()
	if session.state == OnlineSession.State.REJECTED or session.state == OnlineSession.State.FAILED:
		var how := "rejected: " + session.reject_reason if session.state == OnlineSession.State.REJECTED else "failed: " + session.failure
		printerr("client %d: %s" % [seat, how])
		quit(1)
		return false
	if session.state == OnlineSession.State.ENDED and _done_at_ms < 0:
		_done_at_ms = now
	if _done_at_ms >= 0 and now - _done_at_ms > 1500:
		_report()
		quit(0)
	elif now - _started_ms > _max_ms:
		printerr("client %d: the match did not end in time (state %d)" % [seat, session.state])
		quit(1)
	return false


func _lobby() -> void:
	if not _printed_code:
		_printed_code = true
		print("client %d: in room %s, seat %d" % [seat, session.lobby["code"], int(session.lobby["seat"])])
	var named := 0
	var names: PackedStringArray = session.lobby["names"]
	for n in names:
		named += 0 if n.is_empty() else 1
	if _start_room and session.lobby["owner"] and named >= _people and not _sent_start:
		_sent_start = true
		session.send_start()


func _report() -> void:
	var rb: Rollback = session.rollback
	var depths: Array[int] = rb.depths.duplicate()
	depths.sort()
	var p99 := depths[mini(depths.size() - 1, floori(float(depths.size()) * 0.99))] if not depths.is_empty() else 0
	var places: Array = session.end_info.get("places", [])
	var place := str(places[seat]) if seat < places.size() else "?"
	print("client %d: ended. place %s, rollbacks %d (depth p99 %d), resyncs %d, desyncs %d, checksums ok %d, rtt %d ms, confirmed checksum %s" % [
		seat, place, rb.rebuilds, p99, session.resyncs, session.desyncs, session.checksums_ok, session.rtt_ms,
		session.confirmed_match().checksum(),
	])


static func _arg(name: String, fallback: String) -> String:
	var prefix := "--%s=" % name
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with(prefix):
			return argument.trim_prefix(prefix)
	return fallback
