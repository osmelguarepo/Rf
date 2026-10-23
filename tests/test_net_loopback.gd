extends "res://tests/test_case.gd"
## The in-memory transport (scripts/net/loopback_transport.gd; docs/SPEC_ONLINE.md §16.1 4): ordered like TCP, loss
## shows as delay, latency is the configured one, and a seed repeats a run exactly. Time moves only with advance().

const Loopback := preload("res://scripts/net/loopback_transport.gd")
const Transport := preload("res://scripts/net/transport.gd")


## An open pair: connected, with the handshake's one latency already spent.
func _open(seed_value: int, latency: int, jitter: int = 0, loss: float = 0.0) -> Loopback.Link:
	var link := Loopback.pair(seed_value, latency, jitter, loss)
	assert_eq(link.client.connect_to("loopback"), OK)
	link.advance(latency)
	return link


func _packet(n: int) -> PackedByteArray:
	return PackedByteArray([n & 0xFF, (n >> 8) & 0xFF])


func _drain(end: Transport) -> Array[int]:
	var out: Array[int] = []
	end.poll()
	while end.get_available_packet_count() > 0:
		var p := end.get_packet()
		out.append(p[0] | (p[1] << 8))
	return out


func test_the_connection_opens_after_one_latency() -> void:
	var link := Loopback.pair(1, 40)
	assert_eq(link.client.get_state(), Transport.State.CLOSED)
	link.client.connect_to("x")
	assert_eq(link.client.get_state(), Transport.State.CONNECTING)
	link.advance(39)
	assert_eq(link.client.get_state(), Transport.State.CONNECTING)
	link.advance(1)
	assert_eq(link.client.get_state(), Transport.State.OPEN)
	assert_eq(link.server.get_state(), Transport.State.OPEN)


func test_nothing_can_be_sent_before_the_connection_is_open() -> void:
	var link := Loopback.pair(1, 10)
	assert_eq(link.client.send(_packet(1)), ERR_UNCONFIGURED)


func test_a_packet_arrives_after_exactly_the_latency_without_jitter() -> void:
	var link := _open(1, 75)
	link.client.send(_packet(7))
	link.advance(74)
	assert_eq(link.server.get_available_packet_count(), 0, "not a millisecond early")
	link.advance(1)
	assert_eq(_drain(link.server), [7])
	link.server.send(_packet(8))
	link.advance(75)
	assert_eq(_drain(link.client), [8], "both directions")


func test_jitter_stays_within_the_latency_and_the_jitter() -> void:
	var link := _open(5, 50, 30)
	for i in 200:
		var sent_at := link.now_ms()
		link.client.send(_packet(i))
		var waited := 0
		while link.server.get_available_packet_count() == 0:
			link.advance(1)
			waited += 1
		assert_between(link.now_ms() - sent_at, 50, 80)
		link.server.get_packet()


func test_packets_keep_their_order_under_heavy_jitter() -> void:
	var link := _open(9, 20, 200)
	for i in 300:
		link.client.send(_packet(i))
		link.advance(1)
	link.advance(1000)
	var got := _drain(link.server)
	var expected: Array[int] = []
	for i in 300:
		expected.append(i)
	assert_eq(got, expected, "like TCP: late packets hold back the ones behind them")


func test_loss_shows_as_delay_and_never_as_a_missing_or_reordered_packet() -> void:
	var link := _open(3, 30, 10, 0.5)
	for i in 200:
		link.client.send(_packet(i))
		link.advance(5)
	link.advance(10000)
	var got := _drain(link.server)
	assert_eq(got.size(), 200)
	var sorted := got.duplicate()
	sorted.sort()
	assert_eq(got, sorted)


func test_loss_makes_packets_later_than_the_plain_latency() -> void:
	var link := _open(3, 30, 0, 1.0)
	link.client.send(_packet(1))
	link.advance(30)
	assert_eq(link.server.get_available_packet_count(), 0)
	link.advance(30 * Loopback.RETRANSMIT_FACTOR)
	assert_eq(_drain(link.server), [1])


func test_a_stall_delays_without_dropping_or_reordering() -> void:
	var link := _open(2, 20)
	link.client.send(_packet(1))
	link.advance(5)
	link.stall(500)
	link.client.send(_packet(2))
	link.server.send(_packet(100))
	link.advance(400)
	assert_eq(link.server.get_available_packet_count(), 0, "frozen, even for what was due")
	assert_eq(link.client.get_available_packet_count(), 0)
	link.client.send(_packet(3))
	link.advance(100)
	assert_eq(_drain(link.server), [1, 2, 3], "released when the stall ends, in order, even what was sent during it")
	assert_eq(_drain(link.client), [100])
	link.client.send(_packet(4))
	link.advance(19)
	assert_eq(link.server.get_available_packet_count(), 0, "back to the plain latency")
	link.advance(1)
	assert_eq(_drain(link.server), [4])


func test_closing_reaches_the_other_side_after_the_packets_sent_before() -> void:
	var link := _open(4, 25)
	link.client.send(_packet(1))
	link.client.close()
	assert_eq(link.client.get_state(), Transport.State.CLOSED)
	assert_eq(link.server.get_state(), Transport.State.OPEN, "it does not know yet")
	link.advance(25)
	assert_eq(link.server.get_state(), Transport.State.CLOSED)
	assert_eq(_drain(link.server), [1], "what arrived before the close can still be read")
	assert_eq(link.server.send(_packet(2)), ERR_UNCONFIGURED)


func test_empty_and_oversized_packets_are_refused() -> void:
	var link := _open(1, 1)
	assert_eq(link.client.send(PackedByteArray()), ERR_INVALID_PARAMETER)
	var big := PackedByteArray()
	big.resize(Transport.MAX_PACKET + 1)
	assert_eq(link.client.send(big), ERR_INVALID_PARAMETER)


func test_the_same_seed_gives_the_same_arrival_times() -> void:
	assert_eq(_trace(77), _trace(77))
	assert_ne(_trace(77), _trace(78), "another seed, another jitter")


## The ms at which each of 100 packets arrives over a jittery, lossy link.
func _trace(seed_value: int) -> Array[int]:
	var link := _open(seed_value, 40, 60, 0.2)
	var arrivals: Array[int] = []
	var sent := 0
	for t in 1500:
		if t % 10 == 0 and sent < 100:
			link.client.send(_packet(sent))
			sent += 1
		link.advance(1)
		while link.server.get_available_packet_count() > 0:
			link.server.get_packet()
			arrivals.append(link.now_ms())
	return arrivals


func test_the_loopback_can_carry_protocol_messages() -> void:
	var protocol := preload("res://scripts/net/protocol.gd")
	var link := _open(6, 10)
	link.client.send(protocol.encode_input(5, 3, PackedByteArray([1, 1, 1, 1])))
	link.advance(10)
	var msg := protocol.decode(link.server.get_packet())
	assert_eq(msg["tick"], 5)
