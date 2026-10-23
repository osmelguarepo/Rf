extends RefCounted
## A room and N simulated clients over the loopback transport, on a virtual clock (docs/SPEC_ONLINE.md §13 M2, §16.7). The
## tests (tests/test_net_*.gd) and tools/net_sim.gd share it. Nothing here touches the real network or the real time: step()
## moves the clock by one frame (16 or 17 ms, 60 fps on average), delivers what the links hold, polls the host and gives every
## client its frame.
##
## Each client drives its own car with a deterministic pseudo-player (throttle held, steering and nitro changing every
## so often) so cars cross and collide and the predictions get something to be wrong about.

const Host := preload("res://scripts/server/host.gd")
const Room := preload("res://scripts/server/room.gd")
const OnlineSession := preload("res://scripts/net/online_session.gd")
const Loopback := preload("res://scripts/net/loopback_transport.gd")
const Transport := preload("res://scripts/net/transport.gd")
const Ticket := preload("res://scripts/net/ticket.gd")
const NetConfig := preload("res://scripts/net/net_config.gd")
const Match := preload("res://scripts/sim/match.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")

const KEY := "harness-key"
const UNIX_NOW := 1000000


## One simulated player.
class Client extends RefCounted:
	var seat: int = 0
	var session: OnlineSession
	var link: Loopback.Link
	var rng := RandomNumberGenerator.new()
	var accepted: bool = false
	## True: the app is frozen (no frames at all), as a background tab is.
	var frozen: bool = false
	var frame_us: Array[int] = []
	var confirmed_hashes: Dictionary = {}
	var steer: int = 0
	var nitro: bool = true
	var ticket: String = ""
	var latency: int = 0

	func control(frame: int) -> int:
		if frame % 41 == 0:
			steer = rng.randi_range(-1, 1)
		if frame % 97 == 0:
			nitro = rng.randf() < 0.7
		return PlayerInput.encode(true, false, steer, nitro)


var host: Host = Host.new()
var clients: Array[Client] = []
var verifier: Ticket = Ticket.new(KEY, false)
var now_ms: int = 0
var match_id: String = "harness"
var seed_value: int = 7
var seat_count: int = 6
var humans: int = 0b111111
## Tuning overrides (key -> float) the room starts the match with.
var tuning: Dictionary = {}
var track_hashes: bool = true
var server_hashes: Dictionary = {}
var always_rebuild: bool = false
var _frame: int = 0
var _hooked: bool = false


func _init(options: Dictionary = {}) -> void:
	for key: String in options:
		if key != "room":
			set(key, options[key])
	host.verifier = verifier
	host.unix_clock = func() -> int: return UNIX_NOW
	host.room_defaults = {"cfg": NetConfig.encode(tuning)}
	var room_options: Dictionary = options.get("room", {})
	for key: String in room_options:
		host.room_defaults[key] = room_options[key]


## A signed ticket of this harness's match for a seat.
func ticket_for(seat: int, steam_id: String = "") -> String:
	var id := steam_id if not steam_id.is_empty() else "7656119800000%04d" % seat
	return verifier.issue(match_id, seat, id, seed_value, UNIX_NOW + 60, seat_count, humans)


## A client for a seat with its own link: one-way latency and jitter in ms, and `loss` as TCP retransmissions.
func add_client(seat: int, latency: int = 0, jitter: int = 0, loss: float = 0.0, link_seed: int = -1) -> Client:
	var c := Client.new()
	c.seat = seat
	c.latency = latency
	c.rng.seed = 1000 + seat
	c.link = Loopback.pair(link_seed if link_seed >= 0 else 500 + seat, latency, jitter, loss)
	c.session = OnlineSession.new()
	c.session.always_rebuild = always_rebuild
	if track_hashes:
		c.session.on_confirmed = func(tick: int, m: Match) -> void: c.confirmed_hashes[tick] = hash(m.to_array())
	c.ticket = ticket_for(seat)
	c.session.connect_to(c.link.client, "loopback", c.ticket)
	clients.append(c)
	return c


## Reconnects a client on a new link with the same ticket (a new session).
func reconnect(c: Client, latency: int = -1) -> void:
	var fresh := add_client(c.seat, c.latency if latency < 0 else latency, 0, 0.0, 900 + _frame)
	clients.erase(c)
	_release(c)
	fresh.rng = c.rng
	fresh.confirmed_hashes = c.confirmed_hashes


## The room, once the first ticket has made it.
func room() -> Room:
	return host.find(match_id)


## One frame of 16 or 17 ms.
func step() -> void:
	var dt := 16 if _frame % 3 == 0 else 17
	_frame += 1
	now_ms += dt
	for c in clients:
		c.link.advance(dt)
		if not c.accepted and c.link.server.get_state() == Transport.State.OPEN:
			c.accepted = true
			host.accept(c.link.server, now_ms)
	host.poll(now_ms)
	var r := room()
	if r != null and not _hooked and track_hashes:
		_hooked = true
		r.tick_hook = _on_server_tick
	for c in clients:
		if c.frozen:
			continue
		var started := Time.get_ticks_usec()
		c.session.update(now_ms, c.control(_frame))
		c.frame_us.append(Time.get_ticks_usec() - started)


func run_ms(duration_ms: int) -> void:
	var until := now_ms + duration_ms
	while now_ms < until:
		step()


## Runs until the room has ended, or `limit_ms` of virtual time. Returns true if it ended.
func run_until_over(limit_ms: int) -> bool:
	var until := now_ms + limit_ms
	while now_ms < until:
		step()
		var r := room()
		if r != null and r.phase == Room.Phase.ENDED:
			return true
	return false


## Runs until `check` (a Callable returning bool) holds, or `limit_ms`.
func run_until(check: Callable, limit_ms: int) -> bool:
	var until := now_ms + limit_ms
	while now_ms < until:
		step()
		if check.call():
			return true
	return false


func _on_server_tick(r: Room) -> void:
	if r.tick > r.start_tick:
		server_hashes[r.tick] = hash(r.game.to_array())


## How a client's confirmed states compare with the server's: {"checked", "mismatches", "first_bad"}.
func compare(c: Client) -> Dictionary:
	var checked := 0
	var bad := 0
	var first := -1
	for tick: int in c.confirmed_hashes:
		if not server_hashes.has(tick):
			continue
		checked += 1
		if server_hashes[tick] != c.confirmed_hashes[tick]:
			bad += 1
			if first < 0:
				first = tick
	return {"checked": checked, "mismatches": bad, "first_bad": first}


## The value below which `p` (0..1) of the numbers fall.
static func percentile(values: Array, p: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	return float(sorted[mini(sorted.size() - 1, floori(p * float(sorted.size())))])


## Lets go of the callbacks that point back at the harness, so nothing keeps it alive (call it when done).
func dispose() -> void:
	for c in clients:
		_release(c)
	var r := room()
	if r != null:
		r.tick_hook = Callable()
	host.unix_clock = Callable()
	host.on_result = Callable()


func _release(c: Client) -> void:
	c.session.on_confirmed = Callable()
	c.session.on_predicted_tick = Callable()
	c.session.rollback.on_confirmed = Callable()
	c.session.rollback.on_predicted_tick = Callable()
	c.session.close()
