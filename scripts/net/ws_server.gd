extends RefCounted
## The listening end of the WebSocket transport (docs/SPEC_ONLINE.md §3, §11): a TCPServer whose connections are upgraded
## to WebSockets. poll() every frame; take() hands out each connection once its handshake is done, as a WsTransport the
## Host can own. Desktop only (the browser cannot listen).

const WsTransport := preload("res://scripts/net/ws_transport.gd")
const Transport := preload("res://scripts/net/transport.gd")

## A connection that has not finished its handshake in this time is dropped.
const HANDSHAKE_TIMEOUT_MS := 5000
const MAX_HANDSHAKES := 256

var _server := TCPServer.new()
var _handshaking: Array[Dictionary] = []
var _done: Array[WsTransport] = []


## Starts listening on `p_port` (all addresses, or `bind_address`). Returns OK or an Error.
func listen(p_port: int, bind_address: String = "*") -> int:
	return _server.listen(p_port, bind_address)


func port() -> int:
	return _server.get_local_port()


func is_listening() -> bool:
	return _server.is_listening()


## Accepts new TCP connections and moves the handshakes on.
func poll(now_ms: int) -> void:
	while _server.is_connection_available():
		var stream := _server.take_connection()
		if _handshaking.size() >= MAX_HANDSHAKES:
			stream.disconnect_from_host()
			continue
		stream.set_no_delay(true)
		var transport := WsTransport.from_stream(stream)
		if transport != null:
			_handshaking.append({"transport": transport, "since": now_ms})
	var waiting: Array[Dictionary] = []
	for item in _handshaking:
		var transport: WsTransport = item["transport"]
		transport.poll()
		var state := transport.get_state()
		if state == Transport.State.OPEN:
			_done.append(transport)
		elif state == Transport.State.CONNECTING and now_ms - int(item["since"]) < HANDSHAKE_TIMEOUT_MS:
			waiting.append(item)
		else:
			transport.close()
	_handshaking = waiting


## The next connection whose handshake is done, or null.
func take() -> WsTransport:
	return null if _done.is_empty() else _done.pop_front()


func stop() -> void:
	_server.stop()
