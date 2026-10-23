extends "res://tests/test_case.gd"
## The messages M2 adds to the protocol of M1 (scripts/net/protocol.gd): the owner's START, a client's SNAPSHOT_REQ and the
## private room's LOBBY. They follow the same rules: round trips, nothing truncated or padded is accepted, garbage never crashes.

const P := preload("res://scripts/net/protocol.gd")


func test_start_and_snapshot_request_are_a_type_byte_and_nothing_else() -> void:
	assert_eq(P.decode(P.encode_start()), {"type": P.START})
	assert_eq(P.decode(P.encode_snapshot_req()), {"type": P.SNAPSHOT_REQ})
	for bytes: PackedByteArray in [P.encode_start(), P.encode_snapshot_req()]:
		bytes.append(0)
		assert_eq(P.decode(bytes)["error"], P.ERR_TRAILING)


func test_lobby_round_trips_with_names_and_the_secret() -> void:
	var names := PackedStringArray(["ANA", "BOB", "", "", "", "X1"])
	var msg := P.decode(P.encode_lobby("AB3CDE", 1, false, "0a1b2c3d", names))
	assert_eq(msg, {"type": P.LOBBY, "code": "AB3CDE", "seat": 1, "owner": false, "secret": "0a1b2c3d", "names": names})
	assert_true(P.decode(P.encode_lobby("AB3CDE", 0, true, "", PackedStringArray()))["owner"])


func test_lobby_with_too_many_names_or_cut_short_is_refused() -> void:
	var bytes := P.encode_lobby("AB3CDE", 0, true, "x", PackedStringArray(["A", "B"]))
	for n in bytes.size():
		var cut := P.decode(bytes.slice(0, n))
		assert_true(P.is_error(cut), "cut to %d bytes" % n)
	var big := P.encode_lobby("AB3CDE", 0, true, "x", PackedStringArray(["A", "B", "C", "D", "E", "F", "G"]))
	assert_eq(P.decode(big)["error"], P.ERR_BAD_VALUE, "more names than seats")


func test_damaged_new_messages_never_crash_the_decoder() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	var samples: Array[PackedByteArray] = [
		P.encode_start(), P.encode_snapshot_req(), P.encode_lobby("AB3CDE", 2, true, "ff00ff00", PackedStringArray(["A", "", "B"])),
	]
	for i in 1500:
		var bytes := samples[i % samples.size()].duplicate()
		for j in rng.randi_range(1, 4):
			bytes[rng.randi_range(0, bytes.size() - 1)] = rng.randi_range(0, 255)
		var msg := P.decode(bytes)
		assert_true(msg.has("type") or msg.has("error"))
