extends RefCounted
## What the online game needs from a network connection (docs/SPEC_ONLINE.md §5, §11): message-oriented, ordered and
## reliable like TCP, and polled once per frame with no signals, which is how WebSocketPeer is driven. Implementations:
## LoopbackTransport (in memory, for tests) and, in M2, a WebSocket one. The game never knows which one it holds.
##
## Use: connect_to(), then poll() every frame; while get_state() is OPEN, send() and read packets with
## get_available_packet_count() and get_packet(). A connection the other side closed goes to CLOSED, but the packets
## that arrived before still have to be read.

enum State { CLOSED, CONNECTING, OPEN }

## Largest packet send() accepts.
const MAX_PACKET := 65535


## Starts connecting to `address`. Returns OK, or an Error if it cannot start.
func connect_to(_address: String) -> int:
	return ERR_UNAVAILABLE


## Queues one packet. Returns OK, or an Error: the connection is not open, or the packet is empty or too big.
func send(_packet: PackedByteArray) -> int:
	return ERR_UNAVAILABLE


## Moves the connection along and receives what has arrived. Call it once per frame, before reading.
func poll() -> void:
	pass


func get_state() -> State:
	return State.CLOSED


func get_available_packet_count() -> int:
	return 0


## The oldest received packet, or an empty array if there is none.
func get_packet() -> PackedByteArray:
	return PackedByteArray()


## Closes the connection. The other side sees it after the packets already sent.
func close() -> void:
	pass
