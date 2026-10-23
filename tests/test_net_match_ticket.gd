extends "res://tests/test_case.gd"
## The API's match ticket (scripts/net/match_ticket.gd, backend/docs/TICKET.md): the shared test vectors of
## backend/testdata/ticket_vectors.json (parsed, rebuilt byte for byte, accepted exactly when valid), strict base64url, and the
## checks a game server makes.

const MatchTicket := preload("res://scripts/net/match_ticket.gd")
const VECTORS := "res://backend/testdata/ticket_vectors.json"


func _vectors() -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(VECTORS))
	if parsed is Dictionary:
		return parsed
	return {}


func test_every_vector_parses_rebuilds_and_verifies() -> void:
	var file := _vectors()
	assert_false(file.is_empty(), "the vectors file loads")
	var key_hex: String = file["key_hex"]
	var vectors: Array = file["vectors"]
	assert_gt(vectors.size(), 3)
	for v: Dictionary in vectors:
		var label: String = v["name"]
		var verifier := MatchTicket.new(key_hex, v["server_id"])
		var checked := verifier.verify(v["ticket"], int(v["now"]))
		assert_eq(checked["ok"], v["valid"], label)
		if v["valid"]:
			var payload := (v["payload_hex"] as String).hex_decode()
			var fields := MatchTicket.parse_payload(payload)
			assert_eq(fields["seat"], int(v["seat"]), label)
			assert_eq(str(fields["seed"]), v["seed"], label + ": the seed as text")
			assert_eq(fields["match_id"], v["match_id"], label)
			assert_eq(fields["player_id"], v["player_id"], label + ": ids are text")
			assert_eq(fields["steam_id"], v["steam_id"], label)
			assert_eq(fields["name"], v["display_name"], label)
			assert_eq(fields["server_id"], v["server_id"], label)
			assert_eq(fields["expires"], int(v["expires"]), label)
			assert_eq(fields["guest"], (v["steam_id"] as String).is_empty(), label)
			var key := key_hex.hex_decode()
			assert_eq(MatchTicket.build_payload(fields).hex_encode(), v["payload_hex"], label + ": payload rebuilt")
			assert_eq(MatchTicket.hmac(key, payload).hex_encode(), v["mac_hex"], label + ": mac rebuilt")
			assert_eq(MatchTicket.issue(key, fields), v["ticket"], label + ": ticket rebuilt")
			assert_eq(checked["steam_id"], v["steam_id"], label)
			assert_eq(checked["seats"], 6, label)
			assert_eq(checked["humans"], 1 << int(v["seat"]), label)
		else:
			var expected: String = v["error"]
			assert_eq(checked["error"], MatchTicket.ERR_SIGNATURE if expected == "bad signature" else expected, label)


func test_the_biggest_seed_and_player_id_survive() -> void:
	var file := _vectors()
	var found := false
	for v: Dictionary in file["vectors"]:
		if v["seed"] == "9223372036854775807":
			found = true
			var checked := MatchTicket.new(file["key_hex"], v["server_id"]).verify(v["ticket"], int(v["now"]))
			assert_eq(str(checked["seed"]), "9223372036854775807", "2^63 - 1 is exact in a 64-bit int")
			assert_eq(checked["player_id"], v["player_id"])
	assert_true(found)


func test_a_ticket_for_another_server_or_with_another_key_is_refused() -> void:
	var file := _vectors()
	var v: Dictionary = file["vectors"][0]
	assert_eq(MatchTicket.new(file["key_hex"], "other").verify(v["ticket"], int(v["now"]))["error"], MatchTicket.ERR_SERVER)
	var wrong_key := "ff".repeat(32)
	assert_eq(MatchTicket.new(wrong_key, v["server_id"]).verify(v["ticket"], int(v["now"]))["error"], MatchTicket.ERR_SIGNATURE)
	assert_eq(MatchTicket.new("", v["server_id"]).verify(v["ticket"], int(v["now"]))["error"], MatchTicket.ERR_SIGNATURE, "no key, no ticket")


func test_an_expired_ticket_carries_its_fields_so_a_seat_can_be_reclaimed() -> void:
	var file := _vectors()
	var v: Dictionary = file["vectors"][0]
	var verifier := MatchTicket.new(file["key_hex"], v["server_id"])
	var checked := verifier.verify(v["ticket"], int(v["expires"]) + 1)
	assert_false(checked["ok"])
	assert_eq(checked["error"], MatchTicket.ERR_EXPIRED)
	assert_eq(checked["fields"]["player_id"], v["player_id"])
	assert_true(verifier.verify(v["ticket"], int(v["expires"]))["ok"], "valid while now <= expires")


func test_base64url_is_decoded_strictly() -> void:
	assert_eq(MatchTicket.base64url_decode("AQID"), PackedByteArray([1, 2, 3]))
	assert_eq(MatchTicket.base64url_decode("AQI"), PackedByteArray([1, 2]))
	assert_eq(MatchTicket.base64url_decode("AQ"), PackedByteArray([1]))
	assert_eq(MatchTicket.base64url_decode("AQI="), PackedByteArray(), "padding is refused")
	assert_eq(MatchTicket.base64url_decode("AQ+/"), PackedByteArray(), "the standard alphabet is refused")
	assert_eq(MatchTicket.base64url_decode("AR"), PackedByteArray(), "unused bits must be zero")
	assert_eq(MatchTicket.base64url_decode("A"), PackedByteArray(), "one character is no byte")
	assert_eq(MatchTicket.base64url_decode(""), PackedByteArray())
	var bytes := PackedByteArray()
	for i in 40:
		bytes.append((i * 37) & 0xFF)
	assert_eq(MatchTicket.base64url_decode(MatchTicket.base64url_encode(bytes)), bytes, "and the encoder agrees")


func test_a_malformed_payload_is_refused() -> void:
	var key := "00".repeat(32).hex_decode()
	var good := {
		"guest": false, "seat": 2, "seed": 5, "expires": 100, "server_id": "s1", "match_id": "42", "player_id": "7",
		"steam_id": "76561198000000001", "name": "ANA",
	}
	var verifier := MatchTicket.new("00".repeat(32), "s1")
	assert_true(verifier.verify(MatchTicket.issue(key, good), 50)["ok"], "the baseline is good")
	var cases := {
		"seat 6": {"seat": 6}, "short steam id": {"steam_id": "123"}, "letters in the match": {"match_id": "4x"},
		"guest flag with a steam id": {"guest": true}, "lower case name": {"name": "ana"}, "long name": {"name": "ABCDEFGHI"},
		"empty server": {"server_id": ""},
	}
	for label: String in cases:
		var fields := good.duplicate()
		fields.merge(cases[label], true)
		assert_eq(verifier.verify(MatchTicket.issue(key, fields), 50)["error"], MatchTicket.ERR_FORMAT, label)
	var payload := MatchTicket.build_payload(good)
	var wrong_version := payload.duplicate()
	wrong_version[0] = 2
	assert_true(MatchTicket.parse_payload(wrong_version).is_empty(), "version 2")
	var extra := payload.duplicate()
	extra.append(0)
	assert_true(MatchTicket.parse_payload(extra).is_empty(), "a byte too many")
	assert_true(MatchTicket.parse_payload(payload.slice(0, payload.size() - 1)).is_empty(), "a byte too few")
	var flags := payload.duplicate()
	flags[1] = 2
	assert_true(MatchTicket.parse_payload(flags).is_empty(), "an unknown flag bit")
	var big := payload.duplicate()
	big[3] = 0x80
	assert_true(MatchTicket.parse_payload(big).is_empty(), "a seed of 2^63 or more")
	assert_eq(verifier.verify("", 50)["error"], MatchTicket.ERR_FORMAT)
	assert_eq(verifier.verify("not a ticket", 50)["error"], MatchTicket.ERR_FORMAT)


func test_a_guest_ticket_has_no_steam_id() -> void:
	var key := "11".repeat(32)
	var guest := {
		"guest": true, "seat": 0, "seed": 0, "expires": 10, "server_id": "s", "match_id": "1", "player_id": "99",
		"steam_id": "", "name": "",
	}
	var checked := MatchTicket.new(key, "s").verify(MatchTicket.issue(key.hex_decode(), guest), 5)
	assert_true(checked["ok"])
	assert_true(checked["guest"])
	assert_eq(checked["steam_id"], "")
