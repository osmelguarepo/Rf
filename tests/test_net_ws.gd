extends "res://tests/test_case.gd"
## The WebSocket transport (scripts/net/ws_transport.gd, ws_server.gd) over a real localhost socket: the same Transport the
## loopback is, so a client and a server can talk, and a close shows on the other side. The only test here that opens a port.

const WsServer := preload("res://scripts/net/ws_server.gd")
const WsTransport := preload("res://scripts/net/ws_transport.gd")
const Transport := preload("res://scripts/net/transport.gd")
const Protocol := preload("res://scripts/net/protocol.gd")


## Polls both ends until `done` holds or two seconds pass.
func _until(server: WsServer, client: WsTransport, peer: Array, done: Callable) -> bool:
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < 3000:
		server.poll(Time.get_ticks_msec())
		var accepted := server.take()
		if accepted != null:
			peer.append(accepted)
		client.poll()
		for p: WsTransport in peer:
			p.poll()
		if done.call():
			return true
		OS.delay_msec(2)
	return false


func test_a_client_and_a_server_exchange_packets_and_see_the_close() -> void:
	var server := WsServer.new()
	assert_eq(server.listen(0, "127.0.0.1"), OK)
	var port := server.port()
	assert_gt(port, 0)
	var client := WsTransport.new()
	assert_eq(client.connect_to("ws://127.0.0.1:%d" % port), OK)
	var peer: Array = []
	assert_true(_until(server, client, peer, func() -> bool: return client.get_state() == Transport.State.OPEN and not peer.is_empty()), "connected")
	var at_server: WsTransport = peer[0]
	assert_eq(at_server.get_state(), Transport.State.OPEN)
	assert_eq(client.send(Protocol.encode_ping(5)), OK)
	assert_true(_until(server, client, peer, func() -> bool: return at_server.get_available_packet_count() > 0))
	assert_eq(Protocol.decode(at_server.get_packet()), {"type": Protocol.PING, "client_time": 5})
	assert_eq(at_server.send(Protocol.encode_pong(5, 99)), OK)
	assert_true(_until(server, client, peer, func() -> bool: return client.get_available_packet_count() > 0))
	assert_eq(Protocol.decode(client.get_packet()), {"type": Protocol.PONG, "client_time": 5, "server_tick": 99})
	assert_eq(client.send(PackedByteArray()), ERR_INVALID_PARAMETER, "an empty packet is no packet")
	client.close()
	assert_true(_until(server, client, peer, func() -> bool: return at_server.get_state() == Transport.State.CLOSED), "the server sees the close")
	server.stop()
