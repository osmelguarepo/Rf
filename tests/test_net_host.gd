extends "res://tests/test_case.gd"
## The host (scripts/server/host.gd) and the private rooms (scripts/net/room_code.gd): who is let in and who is turned away
## (docs/SPEC_ONLINE.md §16.2), private rooms by six-character code, many rooms in one process, results and replays handed out.

const Harness := preload("res://tools/net_harness.gd")
const Host := preload("res://scripts/server/host.gd")
const Room := preload("res://scripts/server/room.gd")
const Loopback := preload("res://scripts/net/loopback_transport.gd")
const Protocol := preload("res://scripts/net/protocol.gd")
const NetConfig := preload("res://scripts/net/net_config.gd")
const RoomCode := preload("res://scripts/net/room_code.gd")
const Ticket := preload("res://scripts/net/ticket.gd")
const Replay := preload("res://scripts/server/replay.gd")

var _made: Array[Harness] = []
var _links: Array[Loopback.Link] = []


func before_each() -> void:
	_links = []


func after_each() -> void:
	for h in _made:
		h.dispose()
	_made = []


func _harness(options: Dictionary = {}) -> Harness:
	var h := Harness.new(options)
	h.host.seed_rng(99)
	_made.append(h)
	return h


## A connection that has opened and been handed to the host.
func _raw(h: Harness) -> Loopback.Link:
	var link := Loopback.pair(_links.size() + 1, 0)
	link.client.connect_to("x")
	link.advance(0)
	_links.append(link)
	h.host.accept(link.server, h.now_ms)
	return link


func _say(h: Harness, link: Loopback.Link, packet: PackedByteArray, advance_ms: int = 1) -> Array[Dictionary]:
	link.client.send(packet)
	link.advance(0)
	return _hear(h, link, advance_ms)


## Lets the host run `advance_ms` of virtual time and returns what the link's client received.
func _hear(h: Harness, link: Loopback.Link, advance_ms: int = 1) -> Array[Dictionary]:
	h.now_ms += advance_ms
	h.host.poll(h.now_ms)
	link.advance(0)
	var out: Array[Dictionary] = []
	while link.client.get_available_packet_count() > 0:
		out.append(Protocol.decode(link.client.get_packet()))
	return out


## Lets the host run for a while in frames, as it would in the server.
func _run(h: Harness, duration_ms: int) -> void:
	var until := h.now_ms + duration_ms
	while h.now_ms < until:
		h.now_ms += 17
		h.host.poll(h.now_ms)


func _hello(ticket: String, sim_hash: int = -1) -> PackedByteArray:
	return Protocol.encode_hello("test", NetConfig.sim_hash() if sim_hash < 0 else sim_hash, ticket)


func _of_type(msgs: Array[Dictionary], type: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for m in msgs:
		if m.get("type") == type:
			out.append(m)
	return out


func _reject_reason(msgs: Array[Dictionary]) -> String:
	for m in _of_type(msgs, Protocol.EVENT):
		if m["kind"] == Protocol.EVENT_REJECT:
			return (m["data"] as PackedByteArray).get_string_from_ascii()
	return ""


# --- Who gets in -----------------------------------------------------------------------------------------------------


func test_another_protocol_version_is_told_to_update() -> void:
	var h := _harness()
	var link := _raw(h)
	var bytes := _hello(h.ticket_for(0))
	bytes.encode_u16(1, Protocol.VERSION + 1)
	var got := _say(h, link, bytes)
	assert_eq(_reject_reason(got), Host.REJECT_VERSION)
	assert_eq(link.client.get_state(), Loopback.Base.State.CLOSED, "and hung up on")


func test_another_simulation_is_turned_away() -> void:
	var h := _harness()
	var link := _raw(h)
	assert_eq(_reject_reason(_say(h, link, _hello(h.ticket_for(0), NetConfig.sim_hash() ^ 1))), Host.REJECT_SIM)


func test_a_forged_expired_or_unsigned_ticket_is_turned_away() -> void:
	var h := _harness()
	var forged := Ticket.new("not-the-key", false).issue("harness", 0, "1", 7, Harness.UNIX_NOW + 60, 6, 0b111111)
	assert_eq(_reject_reason(_say(h, _raw(h), _hello(forged))), Ticket.ERR_SIGNATURE)
	var old := h.verifier.issue("harness", 0, "1", 7, Harness.UNIX_NOW - 1, 6, 0b111111)
	assert_eq(_reject_reason(_say(h, _raw(h), _hello(old))), Ticket.ERR_EXPIRED)
	var dev := Ticket.issue_dev("harness", 0, "1", 7, 6, 0b111111)
	assert_eq(_reject_reason(_say(h, _raw(h), _hello(dev))), Ticket.ERR_UNSIGNED, "unsigned tickets need --dev")
	assert_eq(_reject_reason(_say(h, _raw(h), _hello("garbage"))), Ticket.ERR_FORMAT)
	assert_eq(h.host.rooms.size(), 0, "none of them made a room")


func test_a_dev_server_takes_unsigned_tickets() -> void:
	var h := _harness()
	h.host.verifier = Ticket.new("", true)
	var link := _raw(h)
	var got := _say(h, link, _hello(Ticket.issue_dev("dev-match", 0, "76561198123456789", 5, 6, 0b000001)))
	assert_eq(_of_type(got, Protocol.WELCOME).size(), 1, "the only person: the match starts at once")
	assert_eq(h.host.find("dev-match").seats[0].steam_id, "76561198123456789")


func test_a_connection_that_says_nothing_is_closed_after_two_seconds() -> void:
	var h := _harness()
	var link := _raw(h)
	_hear(h, link, Host.HELLO_TIMEOUT_MS - 10)
	assert_eq(link.client.get_state(), Loopback.Base.State.OPEN)
	_hear(h, link, 20)
	assert_eq(link.client.get_state(), Loopback.Base.State.CLOSED)
	assert_eq(h.host.pending_count(), 0)


func test_the_first_message_must_be_a_hello() -> void:
	var h := _harness()
	assert_eq(_reject_reason(_say(h, _raw(h), Protocol.encode_ping(5))), Host.REJECT_BAD_HELLO)
	assert_eq(_reject_reason(_say(h, _raw(h), PackedByteArray([250, 1, 2, 3]))), Host.REJECT_BAD_HELLO)


func test_the_first_valid_ticket_makes_the_room_and_the_others_join_it() -> void:
	var h := _harness({"humans": 0b000011})
	var a := _raw(h)
	var b := _raw(h)
	assert_eq(_of_type(_say(h, a, _hello(h.ticket_for(0))), Protocol.WELCOME).size(), 0, "waits for the other person")
	assert_eq(h.host.rooms.size(), 1)
	var got := _say(h, b, _hello(h.ticket_for(1)))
	var welcome := _of_type(got, Protocol.WELCOME)[0]
	assert_eq(welcome["seat"], 1)
	assert_eq(welcome["seed"], h.seed_value)
	assert_eq(welcome["players"][0], "76561198000000000", "Steam ids travel as text")
	assert_eq(_of_type(_hear(h, a), Protocol.WELCOME).size(), 1)
	assert_eq(h.host.rooms.size(), 1, "still one room")


func test_a_ticket_that_disagrees_with_its_room_or_takes_a_seat_twice_is_turned_away() -> void:
	var h := _harness({"humans": 0b000011})
	_say(h, _raw(h), _hello(h.ticket_for(0)))
	var other_seed := h.verifier.issue("harness", 1, "5", h.seed_value + 1, Harness.UNIX_NOW + 60, 6, 0b000011)
	assert_eq(_reject_reason(_say(h, _raw(h), _hello(other_seed))), Host.REJECT_MISMATCH)
	var other_humans := h.verifier.issue("harness", 1, "5", h.seed_value, Harness.UNIX_NOW + 60, 6, 0b000111)
	assert_eq(_reject_reason(_say(h, _raw(h), _hello(other_humans))), Host.REJECT_MISMATCH)
	assert_eq(_reject_reason(_say(h, _raw(h), _hello(h.ticket_for(0)))), Host.REJECT_SEAT, "seat 0 is taken")
	assert_eq(_reject_reason(_say(h, _raw(h), _hello(h.ticket_for(0, "999")))), Host.REJECT_SEAT)


# --- Private rooms ---------------------------------------------------------------------------------------------------


func test_room_codes_are_six_characters_without_look_alikes() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var seen := {}
	for i in 500:
		var code := RoomCode.generate(rng)
		assert_eq(code.length(), 6)
		assert_eq(RoomCode.normalize(code), code)
		seen[code] = true
		for c: String in code:
			assert_false(c in "01OIL", "no look-alikes in " + code)
	assert_gt(seen.size(), 490, "and they differ")
	assert_eq(RoomCode.normalize(" ab3cde "), "AB3CDE")
	assert_eq(RoomCode.normalize("ab3cd"), "", "five characters")
	assert_eq(RoomCode.normalize("AB3CD0"), "", "a zero is no character of a code")
	assert_eq(RoomCode.normalize("AB3CD!"), "")


func test_names_are_cleaned_like_the_leaderboards() -> void:
	assert_eq(RoomCode.clean_name("ana maria!", 0), "ANAMARIA")
	assert_eq(RoomCode.clean_name("abcdefghijkl", 0), "ABCDEFGH")
	assert_eq(RoomCode.clean_name("a", 2), "P3", "too short: the seat's name")
	assert_eq(RoomCode.clean_name("***", 0), "P1")


func test_a_ticket_text_says_what_it_asks_for() -> void:
	assert_eq(RoomCode.parse(RoomCode.new_ticket("ANA")), {"kind": "new", "name": "ANA"})
	assert_eq(RoomCode.parse(RoomCode.join_ticket("ab3cde", "BOB")), {"kind": "join", "code": "AB3CDE", "name": "BOB"})
	assert_eq(RoomCode.parse(RoomCode.rejoin_ticket("AB3CDE", 3, "00ff00ff")), {"kind": "rejoin", "code": "AB3CDE", "seat": 3, "secret": "00ff00ff"})
	for text: String in ["", "new", "new:a:b", "join:AB3CDE", "join:123:BOB", "rejoin:AB3CDE:x:y", "v1.m.0.1.5.9.6.1.sig"]:
		assert_eq(RoomCode.parse(text), {}, text)


func test_a_private_room_is_made_joined_by_code_and_started_by_its_owner() -> void:
	var h := _harness()
	var a := _raw(h)
	var made := _of_type(_say(h, a, _hello(RoomCode.new_ticket("ana"))), Protocol.LOBBY)[0]
	var code: String = made["code"]
	assert_eq(code.length(), 6)
	assert_eq(made["seat"], 0)
	assert_true(made["owner"])
	assert_eq(made["names"], PackedStringArray(["ANA", "", "", "", "", ""]))
	assert_not_null(h.host.find(code))
	var b := _raw(h)
	var joined := _of_type(_say(h, b, _hello(RoomCode.join_ticket(code.to_lower(), "bob"))), Protocol.LOBBY)[0]
	assert_eq(joined["seat"], 1)
	assert_false(joined["owner"])
	assert_eq(joined["names"][1], "BOB")
	var again := _of_type(_hear(h, a), Protocol.LOBBY)[0]
	assert_eq(again["names"], PackedStringArray(["ANA", "BOB", "", "", "", ""]), "everybody sees who is there")
	assert_eq(_of_type(_say(h, b, Protocol.encode_start()), Protocol.WELCOME).size(), 0, "only the owner can start")
	assert_eq(h.host.find(code).phase, Room.Phase.LOBBY)
	_say(h, a, Protocol.encode_start())
	var welcome := _of_type(_hear(h, b), Protocol.WELCOME)[0]
	assert_eq(welcome["seat"], 1)
	assert_eq(welcome["seats"], 6, "bots fill the empty seats")
	assert_eq(welcome["players"], PackedStringArray(["p1", "p2", "", "", "", ""]))
	var room := h.host.find(code)
	assert_eq(room.phase, Room.Phase.RUNNING)
	assert_true(room.private_room)
	assert_false(room.result()["ranked"], "no ranking points")
	assert_eq(room.game.world.players.size(), 6)
	assert_eq(room.humans_mask(), 0b000011)


func test_a_private_room_has_six_seats_and_a_started_one_takes_nobody_new() -> void:
	var h := _harness()
	var first := _raw(h)
	var code: String = _of_type(_say(h, first, _hello(RoomCode.new_ticket("ANA"))), Protocol.LOBBY)[0]["code"]
	for i in 5:
		assert_eq(_of_type(_say(h, _raw(h), _hello(RoomCode.join_ticket(code, "P%d" % i))), Protocol.LOBBY).size(), 1)
	assert_eq(_reject_reason(_say(h, _raw(h), _hello(RoomCode.join_ticket(code, "LATE")))), Host.REJECT_FULL)
	_say(h, first, Protocol.encode_start())
	assert_eq(_reject_reason(_say(h, _raw(h), _hello(RoomCode.join_ticket(code, "LATE")))), Host.REJECT_FULL, "no room for a seventh")


func test_a_code_that_names_no_room_or_a_server_with_no_private_rooms_turns_the_person_away() -> void:
	var h := _harness()
	assert_eq(_reject_reason(_say(h, _raw(h), _hello(RoomCode.join_ticket("ABCDEF", "BOB")))), Host.REJECT_NO_ROOM)
	h.host.allow_private = false
	assert_eq(_reject_reason(_say(h, _raw(h), _hello(RoomCode.new_ticket("ANA")))), Host.REJECT_PRIVATE_OFF)
	assert_eq(h.host.rooms.size(), 0)


func test_a_person_of_a_private_room_comes_back_with_the_secret_and_nobody_else_can() -> void:
	var h := _harness()
	var a := _raw(h)
	var made := _of_type(_say(h, a, _hello(RoomCode.new_ticket("ANA"))), Protocol.LOBBY)[0]
	var code: String = made["code"]
	var b := _raw(h)
	var joined := _of_type(_say(h, b, _hello(RoomCode.join_ticket(code, "BOB"))), Protocol.LOBBY)[0]
	_say(h, a, Protocol.encode_start())
	_run(h, 2000)
	var secret: String = joined["secret"]
	assert_eq(secret.length(), 8)
	b.client.close()
	b.advance(0)
	_hear(h, b, 500)
	assert_false(h.host.find(code).seats[1].connected)
	assert_eq(_reject_reason(_say(h, _raw(h), _hello(RoomCode.rejoin_ticket(code, 1, "00000000")))), Host.REJECT_SEAT, "wrong secret")
	assert_eq(_reject_reason(_say(h, _raw(h), _hello(RoomCode.rejoin_ticket(code, 0, secret)))), Host.REJECT_SEAT, "another seat's secret")
	var back := _raw(h)
	var got := _say(h, back, _hello(RoomCode.rejoin_ticket(code, 1, secret)))
	assert_eq(_of_type(got, Protocol.WELCOME)[0]["seat"], 1)
	assert_eq(_of_type(got, Protocol.SNAPSHOT).size(), 1, "with the state of the match")
	assert_true(h.host.find(code).seats[1].connected)


func test_one_process_runs_many_rooms_at_once() -> void:
	var h := _harness()
	var owners: Array[Loopback.Link] = []
	var codes: Dictionary = {}
	for i in 24:
		var link := _raw(h)
		var code: String = _of_type(_say(h, link, _hello(RoomCode.new_ticket("P%d" % i))), Protocol.LOBBY)[0]["code"]
		codes[code] = true
		owners.append(link)
	assert_eq(codes.size(), 24, "every room has its own code")
	for link: Loopback.Link in owners:
		_say(h, link, Protocol.encode_start())
	var started := h.now_ms
	while h.now_ms < started + 2000:
		h.now_ms += 17
		h.host.poll(h.now_ms)
	assert_eq(h.host.rooms.size(), 24)
	for room in h.host.rooms:
		assert_eq(room.phase, Room.Phase.RUNNING)
		assert_between(room.tick, 115, 121)
	for link: Loopback.Link in owners:
		_hear(h, link, 0)


# --- Results ---------------------------------------------------------------------------------------------------------


func test_a_finished_match_leaves_its_result_and_replay_and_the_room_goes_away() -> void:
	var h := _harness({"humans": 0b000011, "tuning": {"race_finish_px": 1200.0, "match_races": 1}, "room": {"linger_ms": 2000}})
	h.add_client(0, 40, 5)
	h.add_client(1, 40, 5)
	var seen: Array[Dictionary] = []
	h.host.on_result = func(result: Dictionary, _replay: PackedByteArray) -> void: seen.append(result)
	assert_true(h.run_until_over(300000))
	h.step()
	assert_eq(h.host.results.size(), 1)
	assert_eq(seen.size(), 1, "the callback was told")
	var entry := h.host.results[0]
	var result: Dictionary = entry["result"]
	assert_eq(result["match_id"], "harness")
	assert_true(result["complete"])
	assert_eq(result["seats"].size(), 6)
	assert_eq(result["seats"][0]["steam_id"], "76561198000000000")
	assert_true(Replay.run(entry["replay"])["ok"], "its replay plays again to the same end")
	assert_not_null(h.host.find("harness"), "the clients are still reading the end")
	h.run_ms(2500)
	assert_null(h.host.find("harness"), "then the room is let go")
	assert_eq(h.host.rooms.size(), 0)
	assert_eq(h.host.results.size(), 1, "and counted once")
	h.host.on_result = Callable()


func test_a_replay_that_is_not_one_is_refused() -> void:
	assert_false(Replay.run(PackedByteArray([1, 2, 3]))["ok"])
	assert_false(Replay.run(var_to_bytes({"format": 1}))["ok"])
	assert_false(Replay.run(var_to_bytes({"format": 99}))["ok"])
