extends "res://scripts/net/transport.gd"
## The Transport over a WebSocketPeer (docs/SPEC_ONLINE.md §5, §11): the desktop and web clients' connection to a game
## server, and, from a WsServer, the server's end of a client's. One WebSocket message is one packet, binary. The proxy in
## front of the server (Caddy) speaks wss; this speaks ws to it, or to the client directly in development.
##
## poll() has to run every frame: it drives the handshake and the buffers. Packets that arrived before the other side closed
## stay readable after get_state() says CLOSED.

const Self := preload("res://scripts/net/ws_transport.gd")

## Bytes each way the socket may buffer. A snapshot is ~3.3 KB and a stalled client's TICKS pile up, so be generous.
const BUFFER_BYTES := 262144
const MAX_QUEUED := 4096

var _peer: WebSocketPeer = WebSocketPeer.new()
var _inbox: Array[PackedByteArray] = []
var _opened: bool = false


func _init() -> void:
	_peer.inbound_buffer_size = BUFFER_BYTES
	_peer.outbound_buffer_size = BUFFER_BYTES
	_peer.max_queued_packets = MAX_QUEUED


## `address` is a ws:// or wss:// URL.
func connect_to(address: String) -> int:
	if _peer.get_ready_state() != WebSocketPeer.STATE_CLOSED or _opened:
		return ERR_ALREADY_IN_USE
	return _peer.connect_to_url(address)


## The server's end of an accepted TCP connection: it finishes the WebSocket handshake while poll() runs.
static func from_stream(stream: StreamPeer) -> Self:
	var transport := Self.new()
	if transport._peer.accept_stream(stream) != OK:
		return null
	return transport


func send(packet: PackedByteArray) -> int:
	if _peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return ERR_UNCONFIGURED
	if packet.is_empty() or packet.size() > MAX_PACKET:
		return ERR_INVALID_PARAMETER
	return _peer.send(packet, WebSocketPeer.WRITE_MODE_BINARY)


func poll() -> void:
	_peer.poll()
	if _peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_opened = true
	while _peer.get_available_packet_count() > 0:
		_inbox.append(_peer.get_packet())


func get_state() -> State:
	match _peer.get_ready_state():
		WebSocketPeer.STATE_CONNECTING:
			return State.CONNECTING
		WebSocketPeer.STATE_OPEN:
			return State.OPEN
	return State.CLOSED


func get_available_packet_count() -> int:
	return _inbox.size()


func get_packet() -> PackedByteArray:
	if _inbox.is_empty():
		return PackedByteArray()
	return _inbox.pop_front()


func close() -> void:
	_peer.close()
