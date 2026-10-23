extends RefCounted
## An in-memory Transport for tests (docs/SPEC_ONLINE.md §16.1 4). LoopbackTransport.pair() makes a Link with two
## connected Endpoints, `client` and `server`. Like TCP, packets arrive in order and none is lost: a "lost" packet is
## sent again, which only shows as a delay that holds up the packets behind it (head-of-line blocking). There is no real
## time: the Link's clock moves only with Link.advance(delta_ms), and a seeded RandomNumberGenerator draws the jitter
## and the losses, so a run repeats exactly.
##
## One-way delay of a packet = latency_ms + a draw from 0..jitter_ms (+ a retransmission penalty when it is "lost"),
## but never before the packet ahead of it. Link.stall(ms) freezes delivery in both directions for that long, as a
## radio dropout or a frozen tab would; what was held arrives, in order, when the stall ends.

const Base := preload("res://scripts/net/transport.gd")

## Retransmission penalty of a "lost" packet, in multiples of the one-way latency (a rough TCP timeout).
const RETRANSMIT_FACTOR := 3


## Two connected endpoints with the given one-way latency and jitter in ms, and `loss` (0..1) as the chance that a
## packet needs a retransmission.
static func pair(seed_value: int, latency_ms: int = 0, jitter_ms: int = 0, loss: float = 0.0) -> Link:
	return Link.new(seed_value, latency_ms, jitter_ms, loss)


## One end of a Link: a Transport.
class Endpoint extends Base:
	## Weak, so that the Link and its two endpoints do not keep each other alive: whoever holds the Link keeps the pair.
	var _link_ref: WeakRef = null
	var _link: Link:
		get:
			return _link_ref.get_ref() if _link_ref != null else null
	var _side: int = 0
	var _state: Base.State = Base.State.CLOSED
	var _inbox: Array[PackedByteArray] = []

	func connect_to(_address: String) -> int:
		if _link == null:
			return ERR_UNAVAILABLE
		if _state != Base.State.CLOSED or _link.closed:
			return ERR_ALREADY_IN_USE
		_state = Base.State.CONNECTING
		_link.begin_connect()
		return OK

	func send(packet: PackedByteArray) -> int:
		if _state != Base.State.OPEN:
			return ERR_UNCONFIGURED
		if packet.is_empty() or packet.size() > MAX_PACKET:
			return ERR_INVALID_PARAMETER
		if _link == null:
			return ERR_UNAVAILABLE
		_link.enqueue(_side, packet, false)
		return OK

	## Delivery happens in Link.advance(); there is nothing to receive here.
	func poll() -> void:
		pass

	func get_state() -> Base.State:
		return _state

	func get_available_packet_count() -> int:
		return _inbox.size()

	func get_packet() -> PackedByteArray:
		if _inbox.is_empty():
			return PackedByteArray()
		return _inbox.pop_front()

	func close() -> void:
		if _state == Base.State.CLOSED:
			return
		if _state == Base.State.OPEN and _link != null:
			_link.enqueue(_side, PackedByteArray(), true)
		_state = Base.State.CLOSED


## The pair of endpoints and the little network between them.
class Link:
	var client: Endpoint
	var server: Endpoint
	var latency_ms: int
	var jitter_ms: int
	var loss: float
	## Set once either side has closed: the pair cannot be reused.
	var closed: bool = false

	var _rng := RandomNumberGenerator.new()
	var _now: int = 0
	var _stall_until: int = 0
	## Per sender side: packets in flight as {at, data, fin}, and the arrival time of the last one queued.
	var _flight: Array = [[], []]
	var _last_at: Array[int] = [0, 0]
	var _open_at: int = -1

	func _init(seed_value: int, latency: int, jitter: int, loss_rate: float) -> void:
		_rng.seed = seed_value
		latency_ms = latency
		jitter_ms = jitter
		loss = loss_rate
		client = Endpoint.new()
		server = Endpoint.new()
		client._link_ref = weakref(self)
		client._side = 0
		server._link_ref = weakref(self)
		server._side = 1

	func now_ms() -> int:
		return _now

	## Moves the clock on and delivers what is due. This is the only thing that makes time pass.
	func advance(delta_ms: int) -> void:
		_now += maxi(delta_ms, 0)
		if _now < _stall_until:
			return
		if _open_at >= 0 and _now >= _open_at:
			_open_at = -1
			client._state = Base.State.OPEN
			server._state = Base.State.OPEN
		if _open_at >= 0:
			return
		for side in 2:
			var to: Endpoint = server if side == 0 else client
			var queue: Array = _flight[side]
			while not queue.is_empty() and (queue[0] as Dictionary)["at"] <= _now:
				var item: Dictionary = queue.pop_front()
				if item["fin"]:
					to._state = Base.State.CLOSED
					closed = true
				else:
					to._inbox.append(item["data"])

	## Freezes delivery, both ways, until `duration_ms` from now.
	func stall(duration_ms: int) -> void:
		_stall_until = maxi(_stall_until, _now + maxi(duration_ms, 0))

	## Changes the one-way latency and jitter for the packets sent from now on.
	func set_delay(latency: int, jitter: int) -> void:
		latency_ms = latency
		jitter_ms = jitter

	## Either end may ask; the pair opens one latency later (the server end just listens).
	func begin_connect() -> void:
		if _open_at < 0 and client._state != Base.State.OPEN:
			_open_at = _now + latency_ms

	func enqueue(side: int, data: PackedByteArray, fin: bool) -> void:
		var delay := latency_ms
		if jitter_ms > 0:
			delay += _rng.randi_range(0, jitter_ms)
		if loss > 0.0 and _rng.randf() < loss:
			delay += latency_ms * RETRANSMIT_FACTOR
		var at := maxi(_now + delay, _last_at[side])
		_last_at[side] = at
		(_flight[side] as Array).append({"at": at, "data": data, "fin": fin})
