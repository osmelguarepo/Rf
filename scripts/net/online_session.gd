extends RefCounted
## The online client (docs/SPEC_ONLINE.md §6, §16.1): a Transport, the two-state Rollback and the clock, joined. A screen gives
## it the time and the player's control byte each frame (update()) and draws view_match(); it never touches the network.
##
## - Connecting. connect_to() opens the transport; once open it sends HELLO with the ticket. The answer is LOBBY (a private
##   room's waiting room), WELCOME (the match: seat, seed, rules), or an EVENT_REJECT with the reason (`reject_reason`).
## - Clock. PING/PONG measure the round trip; the sample with the smallest one gives the offset to the server's clock (the
##   usual minimum filter). The client runs ahead of the server by the one-way trip plus a lead, so its inputs reach the server
##   before their tick. TICKS tell it how early its inputs arrived (the margin); the 5th percentile of those is kept at
##   MARGIN_TARGET ticks by growing or shrinking the lead, and the clock runs up to ±2 % fast or slow to close the gap to
##   where it should be (a jump of more than SNAP_TICKS is a snap).
## - Ticks. TICKS feed the confirmed state in order (rollback.gd). The tick numbers are checked: a gap, or a CHECKSUM that
##   differs from the confirmed state's at the same tick, asks the server for a SNAPSHOT (`resyncs` counts those; with a healthy
##   run it stays 0).
## - What the screen may show. view_match(): the predicted match, but never in a later phase than the confirmed one (a round
##   or a match is over when the server says so, not when the prediction thinks so). Sounds come from on_predicted_tick, once
##   per tick; results come from the confirmed state and the EVENTs. view_offset() eases the jump a rollback gives a car, for
##   the view only; the simulation never sees it.

const Protocol := preload("res://scripts/net/protocol.gd")
const Transport := preload("res://scripts/net/transport.gd")
const NetConfig := preload("res://scripts/net/net_config.gd")
const Rollback := preload("res://scripts/net/rollback.gd")
const Config := preload("res://scripts/sim/config.gd")
const Match := preload("res://scripts/sim/match.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")

enum State { IDLE, CONNECTING, HANDSHAKE, LOBBY, WAITING, PLAYING, ENDED, REJECTED, FAILED }

const INPUT_LEAD_TICKS := 2.0
const MARGIN_TARGET := 2
const MARGIN_SAMPLES := 40
## TICKS messages between two looks at the margins.
const MARGIN_EVERY := 30
const SNAP_TICKS := 30.0
const SPEED_LIMIT := 0.02
const PING_BURST := 4
const PING_BURST_MS := 100
const PING_EVERY_MS := 1000
const RTT_SAMPLES := 8
## A clock sample older than this is forgotten: the server's clock and the path may have moved.
const SAMPLE_MAX_AGE_MS := 10000
## How fast a rollback's jump fades out of the view: the fraction left after one second.
const OFFSET_DECAY := 0.0001
## The most the lead grows for jitter and retransmissions, in ticks: more would put the inputs past the server's INPUT_FUTURE_MAX.
const MAX_EXTRA_LEAD := 12.0
## Margins are clipped to this range before they steer the lead: a retransmission can delay an input by seconds, and that is not
## a reason to run seconds ahead.
const MARGIN_CLIP_LOW := -8
const MARGIN_CLIP_HIGH := 40
## An input this early is close to being refused as too far ahead.
const MARGIN_TOO_EARLY := 22

var state: State = State.IDLE
var transport: Transport = null
var ticket: String = ""
var reject_reason: String = ""
var failure: String = ""
## The waiting room of a private room: code, seat, owner, secret, names.
var lobby: Dictionary = {}
var seat: int = -1
var seats: int = 0
var players: PackedStringArray = PackedStringArray()
var cfg: Config = null
var rollback: Rollback = Rollback.new()
## Handed to the rollback when the match starts: see rollback.gd.
var on_predicted_tick: Callable = Callable():
	set(value):
		on_predicted_tick = value
		rollback.on_predicted_tick = value
var on_confirmed: Callable = Callable():
	set(value):
		on_confirmed = value
		rollback.on_confirmed = value
var always_rebuild: bool = false
## The next tick to send an input for.
var local_tick: int = 0
## EVENTs the screen has not read: {"kind", "seat", "tick", "data"}.
var events: Array[Dictionary] = []
## How the server ended the match: {"winner", "places", "points", "abandoned"}; empty until it did.
var end_info: Dictionary = {}
var rtt_ms: int = 0
var extra_lead: float = 0.0
var resyncs: int = 0
var desyncs: int = 0
var clock_snaps: int = 0
var checksums_ok: int = 0
## Counters and the clock's speed, for the tools.
var speed_factor: float = 1.0
var ticks_received: int = 0
var gaps: int = 0

var _now_ms: int = 0
var _last_ms: int = -1
var _tick_clock: float = 0.0
var _have_clock: bool = false
var _samples: Array[Vector3] = []
var _offset_ms: float = 0.0
var _pings_sent: int = 0
var _next_ping_ms: int = 0
var _margins: Array[int] = []
var _margin_batches: int = 0
var _checksums: Dictionary = {}
var _offsets: Dictionary = {}
var _asked_snapshot_at: int = -1


## Starts connecting. `address` is whatever the transport takes (a ws:// URL; anything for the loopback). The HELLO goes out
## by itself once the connection is open.
func connect_to(p_transport: Transport, address: String, p_ticket: String) -> int:
	transport = p_transport
	ticket = p_ticket
	state = State.CONNECTING
	var error := transport.connect_to(address)
	if error != OK:
		state = State.FAILED
		failure = "connect"
	return error


## Takes a transport that is already open (a server's loopback end in tests, or a reconnection made elsewhere).
func use_open(p_transport: Transport, p_ticket: String) -> void:
	transport = p_transport
	ticket = p_ticket
	state = State.CONNECTING


func is_active() -> bool:
	return state in [State.LOBBY, State.WAITING, State.PLAYING]


## True once the match is going on (or over) and there is a state to show.
func has_match() -> bool:
	return rollback.confirmed != null


## One frame: reads the network, keeps the clock, sends the inputs of the ticks that are due with `control` (the player's
## held controls), and plays the prediction forward. `now_ms` is any monotonic clock in ms.
func update(now_ms: int, control: int = PlayerInput.NONE) -> void:
	_now_ms = now_ms
	var dt := now_ms - _last_ms if _last_ms >= 0 else 0
	_last_ms = now_ms
	if transport == null or state in [State.IDLE, State.REJECTED, State.FAILED]:
		return
	transport.poll()
	if state == State.CONNECTING:
		if transport.get_state() == Transport.State.OPEN:
			transport.send(Protocol.encode_hello(NetConfig.GAME_VERSION, NetConfig.sim_hash(), ticket))
			state = State.HANDSHAKE
			_next_ping_ms = now_ms
		elif transport.get_state() == Transport.State.CLOSED:
			_fail("closed")
			return
		else:
			return
	while transport.get_available_packet_count() > 0:
		_handle(Protocol.decode(transport.get_packet()))
	if state in [State.REJECTED, State.FAILED]:
		return
	if transport.get_state() == Transport.State.CLOSED and state in [State.HANDSHAKE, State.LOBBY, State.WAITING, State.PLAYING]:
		_fail("disconnected")
		return
	_ping(now_ms)
	if state == State.PLAYING:
		_pace(maxi(dt, 0), control)
	_decay(maxi(dt, 0))


## The owner of a private room starts the match.
func send_start() -> void:
	_send(Protocol.encode_start())


## Leaves: closes the connection.
func close() -> void:
	if transport != null:
		transport.close()
	if state != State.ENDED:
		state = State.IDLE


## The match the screen draws: the predicted one, but never ahead of the confirmed phase.
func view_match() -> Match:
	var m := rollback.predicted
	var c := rollback.confirmed
	if m == null:
		return c
	if m.phase > c.phase or (m.phase == c.phase and m.round_number > c.round_number):
		return c
	return m


## The confirmed match, where results come from.
func confirmed_match() -> Match:
	return rollback.confirmed


## Adds to the jump seat `slot`'s car is easing out of the view (a rollback calls this by itself).
func add_view_offset(slot: int, shift: Vector2) -> void:
	_offsets[slot] = view_offset(slot) + shift


## The jump (px, world) a rollback gave seat `slot`'s car that the view is still easing out; add it to the car's drawn
## position. Zero most of the time.
func view_offset(slot: int) -> Vector2:
	return _offsets.get(slot, Vector2.ZERO)


## The EVENTs since the last call.
func take_events() -> Array[Dictionary]:
	var out := events
	events = []
	return out


## The server's tick now, as the client believes it (float).
func server_tick_estimate(now_ms: int) -> float:
	return (float(now_ms) + _offset_ms) * 0.06


## The lead the clock keeps over the server's, in ticks.
func lead_ticks() -> float:
	return float(rtt_ms) * 0.5 * 0.06 + INPUT_LEAD_TICKS + extra_lead


# --- Receiving -------------------------------------------------------------------------------------------------------


func _handle(msg: Dictionary) -> void:
	if Protocol.is_error(msg):
		return
	match msg["type"]:
		Protocol.LOBBY:
			lobby = {"code": msg["code"], "seat": msg["seat"], "owner": msg["owner"], "secret": msg["secret"], "names": msg["names"]}
			seat = msg["seat"]
			state = State.LOBBY
		Protocol.WELCOME:
			_welcome(msg)
		Protocol.TICKS:
			_ticks(msg)
		Protocol.SNAPSHOT:
			_snapshot(msg)
		Protocol.CHECKSUM:
			_checksums[msg["tick"]] = [msg["checksum"], msg["cfg_digest"]]
			_verify()
		Protocol.PONG:
			_pong(msg)
		Protocol.EVENT:
			_event(msg)


func _welcome(msg: Dictionary) -> void:
	cfg = NetConfig.build(msg["config"])
	if cfg == null or NetConfig.digest(cfg) != msg["cfg_digest"]:
		_fail("config")
		return
	seat = msg["seat"]
	seats = msg["seats"]
	players = msg["players"]
	var humans := 0
	for i in seats:
		if not players[i].is_empty():
			humans |= 1 << i
	var m := NetConfig.new_match(cfg, msg["seed"], seats, humans)
	if m == null:
		_fail("match")
		return
	rollback = Rollback.new()
	rollback.on_predicted_tick = on_predicted_tick
	rollback.on_confirmed = on_confirmed
	rollback.always_rebuild = always_rebuild
	rollback.setup(m, msg["start_tick"], seats, seat)
	_checksums.clear()
	_offsets.clear()
	# The server's tick before the match starts says nothing about its clock: measure again now that it runs.
	_samples.clear()
	_have_clock = false
	_pings_sent = 0
	_next_ping_ms = _now_ms
	state = State.WAITING
	if _have_clock:
		_begin_clock()


func _ticks(msg: Dictionary) -> void:
	if not has_match() or msg["seats"] != seats:
		return
	var margin: int = msg["margin"]
	if margin != 127:
		_margins.append(margin)
		if _margins.size() > MARGIN_SAMPLES:
			_margins.pop_front()
	_margin_batches += 1
	if _margin_batches >= MARGIN_EVERY:
		_margin_batches = 0
		_adapt_lead()
	var first: int = msg["first_tick"]
	var controls: PackedByteArray = msg["controls"]
	var count: int = msg["count"]
	if first > rollback.confirmed_tick:
		gaps += 1
		_ask_snapshot()
		return
	for i in count:
		var tick := first + i
		if tick < rollback.confirmed_tick:
			continue
		rollback.confirm(controls.slice(i * seats, (i + 1) * seats))
		ticks_received += 1
		_verify()
	if state == State.PLAYING or state == State.WAITING:
		if rollback.confirmed.phase == Match.MATCH_OVER and not end_info.is_empty():
			state = State.ENDED


func _snapshot(msg: Dictionary) -> void:
	if not has_match() or msg["tick"] < rollback.confirmed_tick:
		return
	var parsed: Variant = bytes_to_var(msg["state"])
	if not (parsed is Array) or (parsed as Array).size() != 8 + Match.SCALARS.size() or parsed[0] != Match.FORMAT:
		return
	var m := Match.from_array(cfg, parsed)
	if m == null:
		return
	rollback.reset_confirmed(m, msg["tick"])
	local_tick = maxi(local_tick, msg["tick"])
	resyncs += 1
	_asked_snapshot_at = -1
	transport.send(Protocol.encode_ack_snapshot(msg["tick"]))


## Compares the server's checksum for a tick with the confirmed state's, once it has got there.
func _verify() -> void:
	var tick := rollback.confirmed_tick
	if not _checksums.has(tick):
		return
	var entry: Array = _checksums[tick]
	_checksums.erase(tick)
	for old: int in _checksums.keys():
		if old < tick:
			_checksums.erase(old)
	if entry[1] != NetConfig.digest(cfg):
		_fail("config")
		return
	if entry[0] == NetConfig.checksum32(rollback.confirmed):
		checksums_ok += 1
	else:
		desyncs += 1
		_ask_snapshot()


func _ask_snapshot() -> void:
	if _asked_snapshot_at >= 0 and _now_ms - _asked_snapshot_at < 1000:
		return
	_asked_snapshot_at = _now_ms
	_send(Protocol.encode_snapshot_req())


func _event(msg: Dictionary) -> void:
	var kind: int = msg["kind"]
	if kind == Protocol.EVENT_REJECT:
		reject_reason = (msg["data"] as PackedByteArray).get_string_from_ascii()
		state = State.REJECTED
		return
	events.append({"kind": kind, "seat": msg["seat"], "tick": msg["tick"], "data": msg["data"]})
	if kind == Protocol.EVENT_MATCH_END:
		var data: PackedByteArray = msg["data"]
		if data.size() == 1 + 3 * seats:
			var places: Array[int] = []
			var points: Array[int] = []
			var abandoned: Array[bool] = []
			for i in seats:
				places.append(data[1 + 3 * i])
				points.append(data[2 + 3 * i])
				abandoned.append(data[3 + 3 * i] != 0)
			end_info = {"winner": data[0] if data[0] != 0xFF else Match.NO_WINNER, "places": places, "points": points, "abandoned": abandoned}
		if has_match() and rollback.confirmed.phase == Match.MATCH_OVER:
			state = State.ENDED


# --- Clock and inputs ------------------------------------------------------------------------------------------------


func _ping(now_ms: int) -> void:
	if now_ms < _next_ping_ms:
		return
	_send(Protocol.encode_ping(now_ms & 0xFFFFFFFF))
	_pings_sent += 1
	_next_ping_ms = now_ms + (PING_BURST_MS if _pings_sent < PING_BURST else PING_EVERY_MS)


func _pong(msg: Dictionary) -> void:
	var rtt: int = (_now_ms - int(msg["client_time"])) & 0xFFFFFFFF
	var server_ms := float(msg["server_tick"]) * 1000.0 / 60.0 + float(rtt) * 0.5
	_samples.append(Vector3(float(rtt), server_ms - float(_now_ms), float(_now_ms)))
	while _samples.size() > RTT_SAMPLES or float(_now_ms) - _samples[0].z > SAMPLE_MAX_AGE_MS:
		_samples.pop_front()
	var best := _samples[0]
	for sample in _samples:
		if sample.x < best.x:
			best = sample
	rtt_ms = roundi(best.x)
	_offset_ms = best.y
	if not _have_clock:
		_have_clock = true
		if state == State.WAITING:
			_begin_clock()


## Starts the tick clock where the server's will be when the first input arrives.
func _begin_clock() -> void:
	_tick_clock = server_tick_estimate(_now_ms) + lead_ticks()
	local_tick = floori(_tick_clock)
	state = State.PLAYING


func _adapt_lead() -> void:
	if _margins.size() < 8:
		return
	var sorted: Array[int] = []
	for margin in _margins:
		sorted.append(clampi(margin, MARGIN_CLIP_LOW, MARGIN_CLIP_HIGH))
	sorted.sort()
	var low: int = sorted[floori(float(sorted.size()) * 0.05)]
	if sorted.back() >= MARGIN_TOO_EARLY:
		extra_lead = maxf(extra_lead - 4.0, 0.0)
	elif low < MARGIN_TARGET:
		extra_lead = minf(extra_lead + float(MARGIN_TARGET - low) * 0.5, MAX_EXTRA_LEAD)
	elif low > MARGIN_TARGET + 3:
		extra_lead = maxf(extra_lead - 0.25, 0.0)


## Runs the clock for `dt` ms and sends the inputs of the ticks that fall due.
func _pace(dt: int, control: int) -> void:
	var desired := server_tick_estimate(_now_ms) + lead_ticks()
	var error := desired - _tick_clock
	if absf(error) > SNAP_TICKS:
		_tick_clock = desired
		error = 0.0
		clock_snaps += 1
	speed_factor = 1.0 + clampf(error * 0.02, -SPEED_LIMIT, SPEED_LIMIT)
	_tick_clock += float(dt) * 0.06 * speed_factor
	var byte := control & Protocol.CONTROL_MASK
	var target := floori(_tick_clock)
	while local_tick < target:
		if local_tick - rollback.confirmed_tick >= rollback.max_predict:
			_tick_clock = minf(_tick_clock, float(local_tick))
			break
		_send_input(local_tick, byte)
		local_tick += 1
	rollback.advance(local_tick)


func _send_input(tick: int, byte: int) -> void:
	rollback.set_own(tick, byte)
	var history := PackedByteArray()
	for i in Protocol.INPUT_HISTORY:
		history.append(rollback.own_byte(tick - 1 - i))
	_send(Protocol.encode_input(tick, byte, history))


## Eases the jumps the last rollback made out of the view.
func _decay(dt: int) -> void:
	var shift := rollback.last_shift
	if not shift.is_empty():
		for slot: int in shift:
			add_view_offset(slot, shift[slot])
		rollback.last_shift = {}
	if _offsets.is_empty():
		return
	var keep := pow(OFFSET_DECAY, float(dt) / 1000.0)
	for slot: int in _offsets.keys():
		var v: Vector2 = _offsets[slot] * keep
		if v.length() < 0.05:
			_offsets.erase(slot)
		else:
			_offsets[slot] = v


func _send(packet: PackedByteArray) -> void:
	if transport != null and transport.get_state() == Transport.State.OPEN:
		transport.send(packet)


func _fail(reason: String) -> void:
	failure = reason
	state = State.FAILED
	if transport != null:
		transport.close()
