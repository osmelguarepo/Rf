extends RefCounted
## One online match on the game server (docs/SPEC_ONLINE.md §6, §8, §16): the seats, the authoritative tick loop and
## everything it says to the clients. The server builds the canonical input stream (one byte per seat and tick) and runs
## the same Match as the clients; the clients run it too, on that stream, so they arrive at exactly the server's state.
##
## - Time. The room has no clock: poll(now_ms) gets a monotonic one (the host's), and runs every tick that is due since
##   start. It is not the app's FixedStep, which throws a backlog away: here a late poll runs the ticks it owes (up to
##   MAX_CATCH_UP; beyond that the clock slides and the skipped ticks are counted).
## - Ticks. Absolute numbers. Tick T is executed when `tick` == T; the Match steps from `start_tick` on (the lead-in gives
##   the clients time to arrive). INPUT(t) is the control for tick t.
## - Inputs (§6, §10, §16.1). Per seat, the latest accepted one is held: an input for a tick already past is applied now
##   (the past is never rewritten), one up to INPUT_FUTURE_MAX ticks ahead waits for its tick, one further ahead is
##   dropped; at most one per tick (a tick not newer than the last accepted is ignored); bits 5 to 7 are masked and 0xFF
##   is refused by the decoder; the pause bit is gone with the mask, so there is no pause. Nothing new: the last is held.
## - Seats. A person's seat is driven by its connection; a bot's (and a seat nobody took) by the bot byte 0xFF. A person
##   who loses the connection drives on with the held input for `bot_after_ms`, then gets 0xFF (the bot drives, the
##   match counts them as having left); if they come back with the same ticket within `grace_ms` they get the seat back
##   with a SNAPSHOT (Match.step(bytes, true)); after it the 0xFF is final.
## - Rounds. After the end of a race the server adds the CONFIRM press to the stream, CONFIRM_AFTER_TICKS later: nobody
##   confirms, and nobody can hold the others back.
## - Output. TICKS every TICKS_EVERY ticks, to each client with the margin its inputs arrive with; CHECKSUM every
##   CHECKSUM_EVERY ticks (rooms staggered by `stagger`); SNAPSHOT only to a person who asks (after a mismatch) or
##   comes back; EVENT for a race end, a disconnect and the end of the match (with its places).
## - Record. replay_bytes() (replay.gd) and result() (per seat: place, race points, abandoned; SteamIDs as text).
##
## Two ways to open a room: with a ticket from the API (ticketed: seat, Steam id, seed and humans are fixed; it starts
## when all have arrived or JOIN_TIMEOUT has passed) or private (a six-character code, people sit where they arrive, the
## owner starts it, bots fill the rest, no ranking points).

const Protocol := preload("res://scripts/net/protocol.gd")
const Transport := preload("res://scripts/net/transport.gd")
const NetConfig := preload("res://scripts/net/net_config.gd")
const RoomCode := preload("res://scripts/net/room_code.gd")
const Replay := preload("res://scripts/server/replay.gd")
const Config := preload("res://scripts/sim/config.gd")
const Match := preload("res://scripts/sim/match.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")

const Self := preload("res://scripts/server/room.gd")

enum Phase { LOBBY, RUNNING, ENDED }

const TICK_MS := 1000.0 / 60.0
## Ticks between the welcome and the first step.
const PREROLL_TICKS := 60
const INPUT_FUTURE_MAX := 30
const TICKS_EVERY := 2
const CHECKSUM_EVERY := 60
const CONFIRM_AFTER_TICKS := 600
const MAX_CATCH_UP := 30
## A person may ask for a snapshot this often.
const SNAPSHOT_MIN_MS := 1000
## Invalid messages from one connection before it is closed.
const MAX_VIOLATIONS := 25
const BOT := PlayerInput.BOT


## One seat. A bot seat is `human == false`.
class Seat extends RefCounted:
	var index: int = 0
	var human: bool = false
	var steam_id: String = ""
	## The API's player id (text), "" in a private room or a development ticket; and who the seat belongs to: it, or the SteamID.
	var player_id: String = ""
	var identity: String = ""
	var guest: bool = false
	## What the other clients are told this seat is called (WELCOME's player list); the SteamID when empty.
	var label: String = ""
	var player_name: String = ""
	## What lets the person come back to the seat of a private room.
	var secret: String = ""
	var transport: Transport = null
	var connected: bool = false
	var joined: bool = false
	## The grace window is over: the seat is a bot's for good.
	var final: bool = false
	var away_since_ms: int = 0
	var last_input_ms: int = 0
	## The newest input tick accepted, and the inputs waiting for their tick.
	var max_tick: int = -1
	var queue: Dictionary = {}
	## The input held. NONE until the first one arrives.
	var held: int = PlayerInput.NONE
	## Came back and has not sent an input yet: the bot drives until it does.
	var awaiting_input: bool = false
	## First tick not yet sent to this client.
	var next_tick: int = 0
	## Smallest margin (ticks the newest input arrived before it was needed) since the last TICKS; 127 = none.
	var min_margin: int = 127
	var last_snapshot_ms: int = -1000000
	var violations: int = 0
	## The tick of the last SNAPSHOT this client confirmed.
	var acked_snapshot: int = -1


var code: String = ""
var match_id: String = ""
var seed_value: int = 0
var seat_count: int = 6
var cfg_bytes: PackedByteArray = NetConfig.encode()
var cfg: Config = null
var cfg_digest: int = 0
var private_room: bool = false
## Ticketed room: the mask of the seats people take. Private room: 0 until it starts.
var expected_humans: int = 0
var owner: int = -1
var grace_ms: int = 45000
var bot_after_ms: int = 1500
var idle_ms: int = 15000
var join_timeout_ms: int = 15000
## A room from the API's tickets does not know how many people come (a ticket names only its own seat): it takes the humans
## as their tickets arrive and starts `gather_ms` after the first, or when all six seats have a person.
var open_humans: bool = false
var gather_ms: int = 6000
var linger_ms: int = 5000
## Offsets the checksum schedule of this room from the others' (the host sets it).
var stagger: int = 0
var phase: Phase = Phase.LOBBY
var seats: Array[Seat] = []
var game: Match = null
## Ticks executed: the next tick to execute.
var tick: int = 0
var start_tick: int = PREROLL_TICKS
## Called after every executed tick with the room (tests and tools watch the state here).
var tick_hook: Callable = Callable()
## Counters of what the room saw: late_inputs, future_dropped, ignored_inputs, bad_packets, snapshots, skipped_ticks...
var counters: Dictionary = {}
## Slowest Match.step() so far, in microseconds.
var step_max_us: int = 0
## The host has taken the result of the ended room.
var collected: bool = false
var step_total_us: int = 0
var steps_run: int = 0

var _t0_ms: int = 0
var _first_join_ms: int = -1
var _ended_ms: int = 0
## Bytes of every step: seat_count per step.
var _stream := PackedByteArray()
var _final_checksum: String = ""
var _complete: bool = false


## A room from options: code, match_id, seed, seats, humans (ticketed), cfg (the WELCOME config bytes), private, and the
## timing options named like the fields.
static func create(options: Dictionary) -> Self:
	var room := Self.new()
	for key: String in options:
		if key == "cfg":
			room.cfg_bytes = options[key]
		else:
			room.set(key, options[key])
	room.cfg = NetConfig.build(room.cfg_bytes)
	if room.cfg == null:
		room.cfg = Config.game()
		room.cfg_bytes = NetConfig.encode()
	room.cfg_digest = NetConfig.digest(room.cfg)
	for i in room.seat_count:
		var seat := Seat.new()
		seat.index = i
		seat.human = (room.expected_humans & (1 << i)) != 0
		room.seats.append(seat)
	return room


# --- Joining ---------------------------------------------------------------------------------------------------------


## A ticketed person arrives at a seat: the first time (the lobby), or again after losing the connection. False when the
## seat is not theirs, is taken, or has been given up for good.
## `who` has the API ticket's {"player_id", "name", "guest"}.
func join_ticketed(seat_index: int, steam_id: String, transport: Transport, now_ms: int, who: Dictionary = {}) -> bool:
	if phase == Phase.ENDED or seat_index < 0 or seat_index >= seat_count:
		return false
	var seat := seats[seat_index]
	var identity := str(who.get("player_id", steam_id))
	if open_humans and phase == Phase.LOBBY and not seat.human and not seat.joined:
		seat.human = true
		expected_humans |= 1 << seat_index
	if not seat.human or seat.final or seat.connected:
		return false
	if seat.joined and seat.identity != identity:
		return false
	seat.steam_id = steam_id
	seat.identity = identity
	seat.player_id = str(who.get("player_id", ""))
	seat.guest = bool(who.get("guest", false))
	if who.has("player_id"):
		seat.player_name = str(who.get("name", ""))
		seat.label = seat.player_name if not seat.player_name.is_empty() else "P%d" % (seat_index + 1)
	_attach(seat, transport, now_ms)
	if phase == Phase.LOBBY and not open_humans and _all_arrived():
		start(now_ms)
	elif phase == Phase.LOBBY and open_humans and connected_count() >= seat_count:
		start(now_ms)
	return true


## True when the seat has been taken by the person `identity` (their player id, or SteamID): a ticket that has expired may
## still bring them back to it.
func owns_seat(seat_index: int, identity: String) -> bool:
	if seat_index < 0 or seat_index >= seat_count:
		return false
	var seat := seats[seat_index]
	return seat.human and seat.joined and seat.identity == identity


## A person sits at the first free seat of the lobby of a private room. Returns the seat, or -1 if the room is full or
## already started.
func join_private(player_name: String, transport: Transport, now_ms: int) -> int:
	if phase != Phase.LOBBY:
		return -1
	for seat in seats:
		if not seat.joined:
			seat.human = true
			seat.player_name = RoomCode.clean_name(player_name, seat.index)
			seat.steam_id = "p%d" % (seat.index + 1)
			seat.secret = "%08x" % randi()
			if owner < 0:
				owner = seat.index
			_attach(seat, transport, now_ms)
			_send_lobby()
			return seat.index
	return -1


## A person of a private room comes back to a seat with its secret.
func rejoin_private(seat_index: int, secret: String, transport: Transport, now_ms: int) -> bool:
	if phase == Phase.ENDED or seat_index < 0 or seat_index >= seat_count:
		return false
	var seat := seats[seat_index]
	if not seat.human or seat.final or seat.connected or seat.secret.is_empty() or seat.secret != secret:
		return false
	_attach(seat, transport, now_ms)
	if phase == Phase.LOBBY:
		_send_lobby()
	return true


func _attach(seat: Seat, transport: Transport, now_ms: int) -> void:
	seat.transport = transport
	seat.connected = true
	seat.violations = 0
	seat.last_input_ms = now_ms
	if _first_join_ms < 0:
		_first_join_ms = now_ms
	if phase == Phase.RUNNING:
		# Back to a match under way: it needs the whole state, and the bot drives until its first input.
		seat.awaiting_input = true
		seat.max_tick = tick - 1
		seat.queue.clear()
		_send_welcome(seat)
		_send_snapshot(seat, now_ms, true)
	seat.joined = true


func _all_arrived() -> bool:
	for seat in seats:
		if seat.human and not seat.connected:
			return false
	return true


## The people who are connected now.
func connected_count() -> int:
	var n := 0
	for seat in seats:
		if seat.connected:
			n += 1
	return n


## The mask of the seats a person has taken.
func humans_mask() -> int:
	var mask := 0
	for seat in seats:
		if seat.human:
			mask |= 1 << seat.index
	return mask


# --- Starting and the tick loop --------------------------------------------------------------------------------------


## Starts the match: bots take the seats nobody took, everybody connected gets the WELCOME.
func start(now_ms: int) -> void:
	if phase != Phase.LOBBY:
		return
	var humans := expected_humans if not private_room else humans_mask()
	game = NetConfig.new_match(cfg, seed_value, seat_count, humans)
	if game == null:
		phase = Phase.ENDED
		return
	for seat in seats:
		seat.human = (humans & (1 << seat.index)) != 0
		seat.last_input_ms = now_ms
		seat.next_tick = start_tick
		if seat.human and not seat.joined:
			seat.away_since_ms = now_ms - bot_after_ms
	phase = Phase.RUNNING
	_t0_ms = now_ms
	tick = 0
	for seat in seats:
		if seat.connected:
			_send_welcome(seat)


## The owner of a private room asks to start: only they can.
func owner_start(seat_index: int, now_ms: int) -> void:
	if private_room and phase == Phase.LOBBY and seat_index == owner:
		start(now_ms)


## Moves the room on to `now_ms`: runs the ticks that are due, reads what the clients sent, closes what is over.
func poll(now_ms: int) -> void:
	if phase == Phase.LOBBY:
		if _first_join_ms >= 0 and not private_room and now_ms - _first_join_ms >= (gather_ms if open_humans else join_timeout_ms):
			start(now_ms)
		elif private_room and connected_count() == 0 and _first_join_ms >= 0:
			phase = Phase.ENDED
			_ended_ms = now_ms
	if phase == Phase.RUNNING:
		var due := floori(float((now_ms - _t0_ms) * 60) / 1000.0)
		if due - tick > MAX_CATCH_UP:
			var late := due - tick - MAX_CATCH_UP
			_t0_ms += roundi(late * TICK_MS)
			_count("skipped_ticks", late)
			due = tick + MAX_CATCH_UP
		while tick < due and phase == Phase.RUNNING:
			_run_tick(now_ms)
	for seat in seats:
		_read(seat, now_ms)
	if phase == Phase.RUNNING:
		_check_everybody_gone(now_ms)


## True once the match is over and the clients have had linger_ms to read the end.
func finished(now_ms: int) -> bool:
	if phase != Phase.ENDED:
		return false
	return now_ms - _ended_ms >= linger_ms or connected_count() == 0


func _run_tick(now_ms: int) -> void:
	for seat in seats:
		_apply_queue(seat)
	if tick >= start_tick:
		var bytes := PackedByteArray()
		bytes.resize(seat_count)
		for seat in seats:
			bytes[seat.index] = _byte_of(seat, now_ms)
		if game.phase == Match.ROUND_OVER and game.phase_ticks + 1 >= CONFIRM_AFTER_TICKS:
			for seat in seats:
				if bytes[seat.index] != BOT:
					bytes[seat.index] |= PlayerInput.CONFIRM
		var before := Time.get_ticks_usec()
		game.step(bytes, true)
		var spent := Time.get_ticks_usec() - before
		step_max_us = maxi(step_max_us, spent)
		step_total_us += spent
		steps_run += 1
		_stream.append_array(bytes)
	tick += 1
	if tick > start_tick:
		if (game.events & Match.EV_ROUND_OVER) != 0:
			_send_race_end()
		if game.phase == Match.MATCH_OVER:
			_finish(now_ms, true)
		elif (tick - start_tick + stagger) % CHECKSUM_EVERY == 0:
			_broadcast(Protocol.encode_checksum(tick, NetConfig.checksum32(game), cfg_digest))
	_flush(false)
	if tick_hook.is_valid():
		tick_hook.call(self)


## Promotes the inputs that wait for tick `tick`: the newest of them is held from now on.
func _apply_queue(seat: Seat) -> void:
	if seat.queue.is_empty():
		return
	var keys: Array = seat.queue.keys()
	for t: int in keys:
		if t <= tick:
			seat.held = seat.queue[t]
			seat.queue.erase(t)
			seat.awaiting_input = false


## The byte the match gets for a seat at this tick.
func _byte_of(seat: Seat, now_ms: int) -> int:
	if not seat.human:
		return BOT
	if not seat.connected:
		if not seat.joined or now_ms - seat.away_since_ms >= bot_after_ms:
			if not seat.final and now_ms - seat.away_since_ms >= grace_ms:
				seat.final = true
			return BOT
		return seat.held
	if seat.awaiting_input or now_ms - seat.last_input_ms > idle_ms:
		return BOT
	return seat.held


## Ends the room early when every person has been gone for the whole grace window.
func _check_everybody_gone(now_ms: int) -> void:
	for seat in seats:
		if seat.human and (seat.connected or (not seat.final and now_ms - seat.away_since_ms < grace_ms)):
			return
	for seat in seats:
		if seat.human and not seat.final:
			seat.final = true
	_finish(now_ms, false)


func _finish(now_ms: int, complete: bool) -> void:
	if phase == Phase.ENDED:
		return
	_complete = complete
	_final_checksum = game.checksum()
	phase = Phase.ENDED
	_ended_ms = now_ms
	_flush(true)
	_broadcast(Protocol.encode_checksum(tick, NetConfig.checksum32(game), cfg_digest))
	_broadcast(Protocol.encode_event(Protocol.EVENT_MATCH_END, 0xFF, tick, _end_data()))


# --- Reading ---------------------------------------------------------------------------------------------------------


func _read(seat: Seat, now_ms: int) -> void:
	var link := seat.transport
	if link == null:
		return
	link.poll()
	while link.get_available_packet_count() > 0:
		_handle(seat, Protocol.decode(link.get_packet()), now_ms)
		if seat.transport != link:
			return
	if link.get_state() == Transport.State.CLOSED:
		_lost(seat, now_ms)


func _handle(seat: Seat, msg: Dictionary, now_ms: int) -> void:
	if Protocol.is_error(msg):
		_violation(seat, "bad_packets")
		return
	match msg["type"]:
		Protocol.INPUT:
			if phase == Phase.RUNNING:
				_on_input(seat, msg, now_ms)
		Protocol.PING:
			_send(seat, Protocol.encode_pong(msg["client_time"], tick))
		Protocol.ACK_SNAPSHOT:
			seat.acked_snapshot = msg["tick"]
		Protocol.SNAPSHOT_REQ:
			if phase == Phase.RUNNING:
				_send_snapshot(seat, now_ms, false)
		Protocol.START:
			owner_start(seat.index, now_ms)
		Protocol.AWAY:
			_on_away(seat, msg["hidden"], now_ms)
		_:
			_violation(seat, "bad_packets")


## A web client's tab went hidden (the bot drives the seat from now) or came back (it gets the whole match again, as after a lost
## connection, and the bot drives until its first input).
func _on_away(seat: Seat, hidden: bool, now_ms: int) -> void:
	if phase != Phase.RUNNING or not seat.human:
		return
	_count("away_hidden" if hidden else "away_back", 1)
	seat.awaiting_input = true
	seat.max_tick = tick - 1
	seat.queue.clear()
	if not hidden:
		seat.last_input_ms = now_ms
		_send_welcome(seat)
		_send_snapshot(seat, now_ms, true)


func _violation(seat: Seat, counter: String) -> void:
	_count(counter, 1)
	seat.violations += 1
	if seat.violations >= MAX_VIOLATIONS and seat.transport != null:
		seat.transport.close()


## An INPUT: its tick and the four before it (a lost packet's inputs). See the header for the rules.
func _on_input(seat: Seat, msg: Dictionary, now_ms: int) -> void:
	var t: int = msg["tick"]
	seat.last_input_ms = now_ms
	if t - tick < seat.min_margin:
		seat.min_margin = clampi(t - tick, -128, 126)
	if t > tick + INPUT_FUTURE_MAX:
		# Too far ahead: the whole message goes, its history too, or it could push the newest-tick mark up and shut out the real
		# inputs. The margin above still tells the client it is running too far ahead.
		_count("future_dropped", 1)
		return
	var first := seat.max_tick < 0
	var history: PackedByteArray = msg["history"]
	if not first:
		for i in range(history.size() - 1, -1, -1):
			_accept(seat, t - 1 - i, history[i], false)
	_accept(seat, t, msg["byte"], true)


func _accept(seat: Seat, t: int, byte: int, newest: bool) -> void:
	if t < 0 or t <= seat.max_tick:
		if newest:
			_count("ignored_inputs", 1)
		return
	seat.max_tick = t
	var masked := byte & Protocol.CONTROL_MASK
	if t <= tick:
		if t < tick and newest:
			_count("late_inputs", 1)
		seat.held = masked
		seat.queue.clear()
		seat.awaiting_input = false
	else:
		seat.queue[t] = masked


## The connection is gone. In the lobby the seat of a private room is free again; in a match the person is away: the held
## input drives on for a moment, then the bot.
func _lost(seat: Seat, now_ms: int) -> void:
	if seat.transport != null:
		seat.transport.close()
	seat.transport = null
	seat.connected = false
	seat.away_since_ms = now_ms
	if phase == Phase.LOBBY:
		if private_room:
			seat.human = false
			seat.joined = false
			seat.steam_id = ""
			seat.secret = ""
			if owner == seat.index:
				owner = -1
				for other in seats:
					if other.connected:
						owner = other.index
						break
			_send_lobby()
		else:
			seat.joined = false
	elif phase == Phase.RUNNING:
		_count("disconnects", 1)
		_broadcast(Protocol.encode_event(Protocol.EVENT_DISCONNECT, seat.index, tick))


# --- Sending ---------------------------------------------------------------------------------------------------------


func _send(seat: Seat, packet: PackedByteArray) -> void:
	if packet.is_empty() or seat.transport == null or seat.transport.get_state() != Transport.State.OPEN:
		return
	seat.transport.send(packet)


func _broadcast(packet: PackedByteArray) -> void:
	for seat in seats:
		_send(seat, packet)


func _players() -> PackedStringArray:
	var out := PackedStringArray()
	for seat in seats:
		out.append((seat.label if not seat.label.is_empty() else seat.steam_id) if seat.human else "")
	return out


func _send_welcome(seat: Seat) -> void:
	_send(seat, Protocol.encode_welcome(
		seat.index, seed_value, cfg_digest, start_tick, tick, _players(), cfg_bytes
	))


## The state of the match at `tick`, which the client then follows from. `forced` skips the rate limit (a comeback).
func _send_snapshot(seat: Seat, now_ms: int, forced: bool) -> void:
	if not forced and now_ms - seat.last_snapshot_ms < SNAPSHOT_MIN_MS:
		_count("snapshots_refused", 1)
		return
	var packet := Protocol.encode_snapshot(tick, var_to_bytes(game.to_array()))
	if packet.is_empty():
		_count("snapshots_too_big", 1)
		return
	seat.last_snapshot_ms = now_ms
	seat.next_tick = maxi(tick, start_tick)
	if tick <= start_tick:
		return
	_count("snapshots", 1)
	_send(seat, packet)


func _send_lobby() -> void:
	var names := PackedStringArray()
	for seat in seats:
		names.append(seat.player_name if seat.human else "")
	for seat in seats:
		if seat.connected:
			_send(seat, Protocol.encode_lobby(code, seat.index, seat.index == owner, seat.secret, names))


## TICKS to every connected client that is TICKS_EVERY ticks behind (or at all with `force`), and the margin it measured.
func _flush(force: bool) -> void:
	if tick <= start_tick:
		return
	for seat in seats:
		if not seat.connected:
			continue
		var from := maxi(seat.next_tick, start_tick)
		var count := tick - from
		if count <= 0 or (count < TICKS_EVERY and not force):
			continue
		var controls := _stream.slice((from - start_tick) * seat_count, (tick - start_tick) * seat_count)
		_send(seat, Protocol.encode_ticks(from, seat_count, controls, seat.min_margin))
		seat.min_margin = 127
		seat.next_tick = tick


func _send_race_end() -> void:
	var data := PackedByteArray([game.round_number])
	var order := game.race_order
	for i in range(order.size() - seat_count, order.size()):
		data.append(order[i])
	_flush(true)
	_broadcast(Protocol.encode_event(Protocol.EVENT_RACE_END, 0xFF, tick, data))


## The end of the match for the clients: the winner, then per seat its place (1 is the best), race points and whether the
## person had left. A client takes it as the server's word on how the match ended.
func _end_data() -> PackedByteArray:
	var data := PackedByteArray([game.winner & 0xFF])
	var order := game.ranking_order()
	for seat in seats:
		data.append(order.find(seat.index) + 1)
		data.append(game.race_points[seat.index])
		data.append(1 if (game.abandoned_mask & (1 << seat.index)) != 0 else 0)
	return data


func _count(counter: String, amount: int) -> void:
	counters[counter] = int(counters.get(counter, 0)) + amount


# --- Results ---------------------------------------------------------------------------------------------------------


## The result record of the match, for the API (§9, §16.2): per seat its place, race points and whether the person left;
## SteamIDs as text, "" for a bot. `ranked` is false for a private room (no points). Only meaningful once it ended.
func result() -> Dictionary:
	var rows: Array = []
	if game != null:
		var order := game.ranking_order()
		for seat in seats:
			rows.append({
				"seat": seat.index, "steam_id": seat.steam_id if seat.human else "", "bot": not seat.human,
					"player_id": seat.player_id if seat.human else "", "guest": seat.guest,
				"name": seat.player_name, "place": order.find(seat.index) + 1,
				"race_points": game.race_points[seat.index],
				"abandoned": (game.abandoned_mask & (1 << seat.index)) != 0,
			})
	return {
		"match_id": match_id, "code": code, "seed": seed_value, "complete": _complete, "ranked": false,
		"private": private_room, "ticks": maxi(tick - start_tick, 0), "seats": rows, "cfg_digest": cfg_digest,
		"winner": game.winner if game != null else -1, "final_checksum": _final_checksum,
	}


## The replay of the match so far (complete once it ended): replay.gd plays it again.
func replay_bytes() -> PackedByteArray:
	var steps := floori(float(_stream.size()) / float(seat_count))
	return Replay.build({
		"seed": seed_value, "cfg": cfg_bytes, "cfg_digest": cfg_digest, "seats": seat_count, "humans": humans_mask(),
		"steps": steps, "final_checksum": game.checksum() if game != null else "", "match_id": match_id,
		"sim_hash": NetConfig.sim_hash(),
	}, _stream)


## The byte the match was given for a seat at an executed tick (0 if that tick was not executed or has no step).
func stream_byte(at_tick: int, seat_index: int) -> int:
	var index := (at_tick - start_tick) * seat_count + seat_index
	if at_tick < start_tick or index < 0 or index >= _stream.size():
		return 0
	return _stream[index]
