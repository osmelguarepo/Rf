extends RefCounted
## Many rooms in one game-server process (docs/SPEC_ONLINE.md §3, §16.2). The host takes the connections a listener
## produces (accept()), waits for each one's HELLO (HELLO_TIMEOUT_MS, then it is closed), checks it and hands the
## connection to a room:
##
## - the protocol version (in the HELLO decoding) and the simulation hash must be the server's, or the client is told to
##   update (EVENT_REJECT with the reason as text);
## - a match ticket: the first valid one for a match creates its room, the others join it, a ticket that comes again after a
##   lost connection takes its seat back (also after it has expired: the signature still proves it, and the seat must be that
##   person's). The API's ticket (match_ticket.gd, backend/docs/TICKET.md: base64url, signed with this server's key) is what
##   production takes; the stand-in text ticket of ticket.gd (it has dots: "v1.MATCH.SEAT...", "dev....") is for tools and tests
##   and is refused unless `legacy_enabled` (the server sets it only with --dev);
## - a private-room ticket (room_code.gd): "new:NAME" makes a room with a six-character code and no ranking points,
##   "join:CODE:NAME" sits at its first free seat, "rejoin:CODE:SEAT:SECRET" comes back to a seat.
## Every room is polled with the same monotonic `now_ms`. A room that ends leaves its result record and replay in
## `results` (and goes to `on_result`) and is dropped once its clients have read the end.

const Self := preload("res://scripts/server/host.gd")
const Room := preload("res://scripts/server/room.gd")
const Protocol := preload("res://scripts/net/protocol.gd")
const Transport := preload("res://scripts/net/transport.gd")
const NetConfig := preload("res://scripts/net/net_config.gd")
const Ticket := preload("res://scripts/net/ticket.gd")
const MatchTicket := preload("res://scripts/net/match_ticket.gd")
const RoomCode := preload("res://scripts/net/room_code.gd")

const HELLO_TIMEOUT_MS := 2000
const MAX_ROOMS := 400
## Reasons of EVENT_REJECT, as text in its data.
const REJECT_BAD_HELLO := "bad_hello"
const REJECT_VERSION := "version"
const REJECT_SIM := "sim_hash"
const REJECT_FULL := "full"
const REJECT_NO_ROOM := "no_room"
const REJECT_SEAT := "seat"
const REJECT_MISMATCH := "mismatch"
const REJECT_PRIVATE_OFF := "private_off"
const REJECT_DRAINING := "draining"


class Pending extends RefCounted:
	var transport: Transport
	var since_ms: int = 0


## The stand-in text ticket's verifier (tools and tests), used only while `legacy_enabled`.
var verifier: Ticket = Ticket.new()
var legacy_enabled: bool = true
## The API ticket's verifier. Without a key every API ticket is refused.
var match_verifier: MatchTicket = MatchTicket.new()
## True once the API asked this server to drain: matches under way finish, no new match starts.
var draining: bool = false
var region: String = ""
var allow_private: bool = true
## Options every new room gets besides its own (grace_ms, bot_after_ms, cfg ...): Room.create() keys.
var room_defaults: Dictionary = {}
## The Unix clock, for ticket expiry: the system's when empty. Tests give another.
var unix_clock: Callable = Callable()
## Called with (result, replay_bytes) when a match ends.
var on_result: Callable = Callable()
## {"result": Dictionary, "replay": PackedByteArray} of the matches that ended, oldest first.
var results: Array[Dictionary] = []
var rooms: Array[Room] = []
var counters: Dictionary = {}

var _pending: Array[Pending] = []
var _by_code: Dictionary = {}
var _by_match: Dictionary = {}
var _rng := RandomNumberGenerator.new()
var _created: int = 0
var _sim_hash: int = 0


func _init() -> void:
	_rng.randomize()
	_sim_hash = NetConfig.sim_hash()


## Makes private-room codes and seeds repeatable (tests).
func seed_rng(seed_value: int) -> void:
	_rng.seed = seed_value


## A connection that has opened. The host owns it from here.
func accept(transport: Transport, now_ms: int) -> void:
	var p := Pending.new()
	p.transport = transport
	p.since_ms = now_ms
	_pending.append(p)


func poll(now_ms: int) -> void:
	var waiting: Array[Pending] = []
	for p in _pending:
		p.transport.poll()
		if p.transport.get_available_packet_count() > 0:
			_hello(p, Protocol.decode(p.transport.get_packet()), now_ms)
		elif p.transport.get_state() == Transport.State.CLOSED or now_ms - p.since_ms > HELLO_TIMEOUT_MS:
			_count("hello_timeouts", 1)
			p.transport.close()
		else:
			waiting.append(p)
	_pending = waiting
	var open: Array[Room] = []
	for room in rooms:
		room.poll(now_ms)
		if room.phase == Room.Phase.ENDED and not room.collected:
			_collect(room)
		if room.finished(now_ms):
			_forget(room)
		else:
			open.append(room)
	rooms = open


## The room with a private code or a match id, or null.
func find(key: String) -> Room:
	return _by_code.get(key, _by_match.get(key))


func pending_count() -> int:
	return _pending.size()


## Matches under way (rooms that have not been forgotten).
func active_matches() -> int:
	return rooms.size()


func _hello(p: Pending, msg: Dictionary, now_ms: int) -> void:
	if Protocol.is_error(msg):
		_reject(p, REJECT_VERSION if msg["error"] == Protocol.ERR_VERSION else REJECT_BAD_HELLO)
		return
	if msg["type"] != Protocol.HELLO:
		_reject(p, REJECT_BAD_HELLO)
		return
	if msg["sim_hash"] != _sim_hash:
		_reject(p, REJECT_SIM)
		return
	var ticket: String = msg["ticket"]
	var wish := RoomCode.parse(ticket)
	if not wish.is_empty():
		_private(p, wish, now_ms)
		return
	var checked := _check(ticket)
	if not checked["ok"]:
		_reject(p, checked["error"])
		return
	var room: Room = _by_match.get(checked["match_id"])
	if room == null:
		if draining:
			_reject(p, REJECT_DRAINING)
			return
		if rooms.size() >= MAX_ROOMS:
			_reject(p, REJECT_FULL)
			return
		room = _make_room({
			"match_id": checked["match_id"], "code": checked["match_id"], "seed_value": checked["seed"],
			"seat_count": checked["seats"], "expected_humans": checked["humans"], "open_humans": checked.get("open", false),
		})
		_by_match[room.match_id] = room
	elif room.seed_value != checked["seed"] or room.seat_count != checked["seats"]  or (not room.open_humans and room.expected_humans != checked["humans"]):
		_reject(p, REJECT_MISMATCH)
		return
	if not room.join_ticketed(checked["seat"], checked["steam_id"], p.transport, now_ms, checked.get("who", {})):
		_reject(p, REJECT_SEAT)


## Checks a ticket of either kind. An API ticket that has expired still passes when its match's room exists and the seat is that
## person's: they are coming back to it.
func _check(ticket: String) -> Dictionary:
	var now := _unix_now()
	if ticket.contains("."):
		if not legacy_enabled:
			return {"ok": false, "error": Ticket.ERR_FORMAT}
		return verifier.verify(ticket, now)
	var checked := match_verifier.verify(ticket, now)
	if not checked["ok"] and checked["error"] == MatchTicket.ERR_EXPIRED:
		var fields: Dictionary = checked["fields"]
		var room: Room = _by_match.get(fields["match_id"])
		if room != null and room.owns_seat(int(fields["seat"]), str(fields["player_id"])):
			checked = MatchTicket.accepted(fields)
	if checked["ok"]:
		checked["who"] = {"player_id": checked["player_id"], "name": checked["name"], "guest": checked["guest"]}
	return checked


func _private(p: Pending, wish: Dictionary, now_ms: int) -> void:
	if not allow_private:
		_reject(p, REJECT_PRIVATE_OFF)
		return
	var room: Room = null
	if wish["kind"] == "new":
		if rooms.size() >= MAX_ROOMS:
			_reject(p, REJECT_FULL)
			return
		var code := RoomCode.generate(_rng)
		while _by_code.has(code):
			code = RoomCode.generate(_rng)
		room = _make_room({
			"code": code, "match_id": code, "seed_value": _rng.randi(), "seat_count": 6, "private_room": true,
		})
		_by_code[code] = room
		if room.join_private(wish["name"], p.transport, now_ms) < 0:
			_reject(p, REJECT_FULL)
		return
	room = _by_code.get(wish["code"])
	if room == null or not room.private_room:
		_reject(p, REJECT_NO_ROOM)
	elif wish["kind"] == "join":
		if room.join_private(wish["name"], p.transport, now_ms) < 0:
			_reject(p, REJECT_FULL)
	elif not room.rejoin_private(wish["seat"], wish["secret"], p.transport, now_ms):
		_reject(p, REJECT_SEAT)


func _make_room(options: Dictionary) -> Room:
	var all := room_defaults.duplicate()
	all.merge(options, true)
	all["stagger"] = (_created * 7) % Room.CHECKSUM_EVERY
	_created += 1
	var room := Room.create(all)
	rooms.append(room)
	_count("rooms_created", 1)
	return room


func _reject(p: Pending, reason: String) -> void:
	_count("rejected", 1)
	_count("rejected_" + reason, 1)
	p.transport.send(Protocol.encode_event(Protocol.EVENT_REJECT, 0xFF, 0, reason.to_ascii_buffer()))
	p.transport.close()


func _collect(room: Room) -> void:
	room.collected = true
	var entry := {"result": room.result(), "replay": room.replay_bytes()}
	results.append(entry)
	if on_result.is_valid():
		on_result.call(entry["result"], entry["replay"])


func _forget(room: Room) -> void:
	_by_code.erase(room.code)
	_by_match.erase(room.match_id)
	for seat in room.seats:
		if seat.transport != null:
			seat.transport.close()


func _unix_now() -> int:
	if unix_clock.is_valid():
		return unix_clock.call()
	return int(Time.get_unix_time_from_system())


func _count(counter: String, amount: int) -> void:
	counters[counter] = int(counters.get(counter, 0)) + amount
