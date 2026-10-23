extends "res://tests/test_case.gd"
## The online protocol (scripts/net/protocol.gd; docs/SPEC_ONLINE.md §5 and §16): every message round-trips, and nothing
## a peer can send makes decode() crash or log an error.

const P := preload("res://scripts/net/protocol.gd")

## Beyond 2^53, where a double stops holding every integer.
const BIG_ID := "76561198000000001"


func test_hello_round_trips_with_the_version() -> void:
	var msg := P.decode(P.encode_hello("0.9.1", 0xDEADBEEF, "ticket-" + BIG_ID))
	assert_eq(msg, {"type": P.HELLO, "game_version": "0.9.1", "sim_hash": 0xDEADBEEF, "ticket": "ticket-" + BIG_ID})


func test_a_hello_with_another_protocol_version_is_reported() -> void:
	var bytes := P.encode_hello("0.9.1", 1, "t")
	bytes.encode_u16(1, P.VERSION + 1)
	var msg := P.decode(bytes)
	assert_true(P.is_error(msg))
	assert_eq(msg["error"], P.ERR_VERSION)
	assert_eq(msg["version"], P.VERSION + 1, "the server can tell the client what it saw")


func test_input_round_trips_with_its_last_four_bytes() -> void:
	var msg := P.decode(P.encode_input(123456, 0b10101, PackedByteArray([1, 2, 3, 4])))
	assert_eq(msg["type"], P.INPUT)
	assert_eq(msg["tick"], 123456)
	assert_eq(msg["byte"], 0b10101)
	assert_eq(msg["history"], PackedByteArray([1, 2, 3, 4]))


func test_input_history_is_padded_and_cut_to_four() -> void:
	assert_eq(P.decode(P.encode_input(1, 2))["history"], PackedByteArray([0, 0, 0, 0]))
	assert_eq(P.decode(P.encode_input(1, 2, PackedByteArray([1, 2, 3, 4, 5, 6])))["history"], PackedByteArray([1, 2, 3, 4]))


func test_input_masks_bits_5_to_7_in_the_byte_and_the_history() -> void:
	var msg := P.decode(P.encode_input(9, 0b11100011, PackedByteArray([0b10000001, 0b01000010, 0b00100100, 0b11011000])))
	assert_eq(msg["byte"], 0b00000011)
	assert_eq(msg["history"], PackedByteArray([0b1, 0b10, 0b100, 0b11000]))


func test_input_with_ff_is_rejected_in_the_byte_and_in_the_history() -> void:
	var msg := P.decode(P.encode_input(9, 0xFF))
	assert_eq(msg["error"], P.ERR_BAD_VALUE)
	msg = P.decode(P.encode_input(9, 0, PackedByteArray([0, 0, 0xFF, 0])))
	assert_eq(msg["error"], P.ERR_BAD_VALUE)


func test_ping_pong_and_ack_round_trip() -> void:
	assert_eq(P.decode(P.encode_ping(4000000000)), {"type": P.PING, "client_time": 4000000000})
	assert_eq(P.decode(P.encode_ack_snapshot(77)), {"type": P.ACK_SNAPSHOT, "tick": 77})
	assert_eq(P.decode(P.encode_pong(5, 6)), {"type": P.PONG, "client_time": 5, "server_tick": 6})


func test_welcome_round_trips_and_steam_ids_stay_text() -> void:
	var players := PackedStringArray([BIG_ID, "76561198999999999", "", "x"])
	var config := PackedByteArray([9, 8, 7])
	var msg := P.decode(P.encode_welcome(2, -123456789012345, 0xCAFEF00D, 180, 5, players, config))
	assert_eq(msg["type"], P.WELCOME)
	assert_eq(msg["seat"], 2)
	assert_eq(msg["seats"], 4)
	assert_eq(msg["seed"], -123456789012345)
	assert_eq(msg["cfg_digest"], 0xCAFEF00D)
	assert_eq(msg["start_tick"], 180)
	assert_eq(msg["server_tick"], 5)
	assert_eq(msg["players"], players)
	assert_eq(msg["players"][0], BIG_ID, "not squeezed through a double")
	assert_eq(msg["config"], config)


func test_welcome_with_a_seat_outside_the_field_is_rejected() -> void:
	var players := PackedStringArray(["a", "b"])
	assert_eq(P.decode(P.encode_welcome(2, 1, 0, 0, 0, players, PackedByteArray()))["error"], P.ERR_BAD_VALUE)
	assert_eq(P.decode(P.encode_welcome(0, 1, 0, 0, 0, PackedStringArray(), PackedByteArray()))["error"], P.ERR_BAD_VALUE)


func test_ticks_round_trips_with_the_margin_and_keeps_bot_bytes() -> void:
	var controls := PackedByteArray([1, 2, 0xFF, 4, 5, 6])
	var msg := P.decode(P.encode_ticks(600, 3, controls, -3))
	assert_eq(msg["first_tick"], 600)
	assert_eq(msg["seats"], 3)
	assert_eq(msg["count"], 2)
	assert_eq(msg["margin"], -3)
	assert_eq(msg["controls"], controls, "0xFF is the server's own bot byte: only a client's is refused")
	assert_eq(P.decode(P.encode_ticks(0, 2, controls.slice(0, 2), 500))["margin"], 127, "clamped")


func test_ticks_that_do_not_fill_whole_ticks_are_rejected() -> void:
	assert_eq(P.decode(P.encode_ticks(0, 3, PackedByteArray([1, 2, 3, 4])))["error"], P.ERR_BAD_VALUE)
	assert_eq(P.decode(P.encode_ticks(0, 3, PackedByteArray()))["error"], P.ERR_BAD_VALUE)
	assert_eq(P.decode(P.encode_ticks(0, 0, PackedByteArray([1])))["error"], P.ERR_BAD_VALUE)


func test_snapshot_and_checksum_round_trip() -> void:
	var state := PackedByteArray()
	state.resize(3300)
	state.fill(0x5A)
	var msg := P.decode(P.encode_snapshot(120, state))
	assert_eq(msg["tick"], 120)
	assert_eq(msg["state"], state)
	assert_eq(P.decode(P.encode_checksum(60, 0xFFFFFFFF, 0x12345678)),
			{"type": P.CHECKSUM, "tick": 60, "checksum": 0xFFFFFFFF, "cfg_digest": 0x12345678})


func test_event_round_trips() -> void:
	var msg := P.decode(P.encode_event(P.EVENT_DISCONNECT, 4, 999, PackedByteArray([1, 2])))
	assert_eq(msg, {"type": P.EVENT, "kind": P.EVENT_DISCONNECT, "seat": 4, "tick": 999, "data": PackedByteArray([1, 2])})
	assert_eq(P.decode(P.encode_event(P.EVENT_REJECT, 0, 0))["kind"], P.EVENT_REJECT)
	assert_eq(P.decode(P.encode_event(P.EVENT_REJECT + 1, 0, 0))["error"], P.ERR_BAD_VALUE)


func test_the_digest_follows_the_configuration() -> void:
	assert_eq(P.digest32(PackedByteArray()), 0x811C9DC5)
	assert_eq(P.digest32("a".to_utf8_buffer()), 0xE40C292C, "FNV-1a of a")
	assert_ne(P.digest32(PackedByteArray([1, 2])), P.digest32(PackedByteArray([2, 1])))


func test_empty_oversized_and_unknown_messages_are_rejected() -> void:
	assert_eq(P.decode(PackedByteArray())["error"], P.ERR_EMPTY)
	var big := PackedByteArray()
	big.resize(P.MAX_MESSAGE + 1)
	big[0] = P.SNAPSHOT
	assert_eq(P.decode(big)["error"], P.ERR_OVERSIZED)
	assert_eq(P.decode(PackedByteArray([0]))["error"], P.ERR_UNKNOWN_TYPE)
	assert_eq(P.decode(PackedByteArray([200, 1, 2]))["error"], P.ERR_UNKNOWN_TYPE)
	assert_eq(P.encode_snapshot(1, big), PackedByteArray(), "an oversized snapshot is not built")


func test_every_truncation_of_every_message_is_rejected_cleanly() -> void:
	# These end in a free-length tail, so a cut inside the tail is a shorter, valid message: only the header must be whole.
	var header := {P.SNAPSHOT: 5, P.EVENT: 7, P.TICKS: 8}
	for msg in _samples():
		var whole: int = header.get(msg[0], msg.size())
		for n in msg.size():
			var cut := P.decode(msg.slice(0, n))
			if n < whole:
				assert_true(P.is_error(cut), "type %d cut to %d bytes" % [msg[0], n])
			else:
				assert_true(cut.has("type") or cut.has("error"))


func test_trailing_bytes_after_a_fixed_message_are_rejected() -> void:
	for bytes: PackedByteArray in [P.encode_ping(1), P.encode_input(1, 1), P.encode_checksum(1, 2, 3)]:
		bytes.append(0)
		assert_eq(P.decode(bytes)["error"], P.ERR_TRAILING)


func test_garbage_never_crashes_or_logs() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261023
	var samples := _samples()
	for i in 3000:
		var bytes := PackedByteArray()
		if i % 3 == 0:
			# Pure noise, with a valid type byte half of the time.
			bytes.resize(rng.randi_range(0, 300))
			for j in bytes.size():
				bytes[j] = rng.randi_range(0, 255)
			if not bytes.is_empty() and i % 2 == 0:
				bytes[0] = [1, 2, 3, 4, 16, 17, 18, 19, 20, 21][rng.randi_range(0, 9)]
		else:
			# A valid message with a few bytes damaged.
			bytes = samples[rng.randi_range(0, samples.size() - 1)].duplicate()
			for j in rng.randi_range(1, 4):
				bytes[rng.randi_range(0, bytes.size() - 1)] = rng.randi_range(0, 255)
		var msg := P.decode(bytes)
		assert_true(msg.has("type") or msg.has("error"))
	var huge := PackedByteArray()
	huge.resize(300000)
	assert_eq(P.decode(huge)["error"], P.ERR_OVERSIZED)


func test_text_that_is_not_printable_ascii_is_rejected_without_engine_errors() -> void:
	var bytes := P.encode_hello("ab", 1, "t")
	bytes[4] = 0xC3
	assert_eq(P.decode(bytes)["error"], P.ERR_BAD_VALUE)
	bytes[4] = 0x07
	assert_eq(P.decode(bytes)["error"], P.ERR_BAD_VALUE)


func test_a_long_string_length_does_not_read_past_the_end() -> void:
	# HELLO claiming a 255-byte game version with 2 bytes behind it; WELCOME claiming 60000 bytes of config.
	var bytes := PackedByteArray([P.HELLO, P.VERSION, 0, 255, 65, 66])
	assert_eq(P.decode(bytes)["error"], P.ERR_TRUNCATED)
	var welcome := P.encode_welcome(0, 1, 2, 3, 4, PackedStringArray(["a"]), PackedByteArray())
	welcome.encode_u16(welcome.size() - 2, 60000)
	assert_eq(P.decode(welcome)["error"], P.ERR_TRUNCATED)


func _samples() -> Array[PackedByteArray]:
	var out: Array[PackedByteArray] = [
		P.encode_hello("1.0", 7, "ticket"),
		P.encode_input(100, 5, PackedByteArray([1, 2, 3, 4])),
		P.encode_ping(1),
		P.encode_ack_snapshot(2),
		P.encode_welcome(1, 42, 3, 4, 5, PackedStringArray([BIG_ID, "2"]), PackedByteArray([1, 2, 3])),
		P.encode_ticks(10, 2, PackedByteArray([1, 2, 3, 4]), 1),
		P.encode_snapshot(60, PackedByteArray([1, 2, 3])),
		P.encode_checksum(60, 1, 2),
		P.encode_pong(1, 2),
		P.encode_event(P.EVENT_RACE_END, 0, 5, PackedByteArray([9])),
	]
	return out
