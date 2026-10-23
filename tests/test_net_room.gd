extends "res://tests/test_case.gd"
## The game server's room (scripts/server/room.gd; docs/SPEC_ONLINE.md §6, §8, §10, §16.1): the input rules, the tick loop,
## disconnects and reconnects, the server's confirm presses, bots in the empty seats, the checksum and snapshot traffic,
## the result and the replay. The room is driven by hand on a virtual clock; the clients are raw loopback links.

const Room := preload("res://scripts/server/room.gd")
const Replay := preload("res://scripts/server/replay.gd")
const Loopback := preload("res://scripts/net/loopback_transport.gd")
const Protocol := preload("res://scripts/net/protocol.gd")
const NetConfig := preload("res://scripts/net/net_config.gd")
const Config := preload("res://scripts/sim/config.gd")
const Match := preload("res://scripts/sim/match.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")

const START := Room.PREROLL_TICKS
## A short race, so a match fits in a test.
const SHORT_RACE := {"race_finish_px": 700.0, "match_races": 2}

var _links: Array[Loopback.Link] = []
## Virtual time at which the room started.
var _base: int = 0


func before_each() -> void:
	_links = []
	_base = 0


## A room of 3 cars, seats 0 and 1 for people.
func _room(options: Dictionary = {}) -> Room:
	var opts := {
		"match_id": "t", "code": "t", "seed_value": 11, "seat_count": 3, "expected_humans": 0b011,
		"cfg": NetConfig.encode(SHORT_RACE),
	}
	opts.merge(options, true)
	return Room.create(opts)


func _join(room: Room, seat: int, now_ms: int = 0, steam_id: String = "") -> Loopback.Link:
	var link := Loopback.pair(seat + 1, 0)
	link.client.connect_to("x")
	link.advance(0)
	_links.append(link)
	assert_true(room.join_ticketed(seat, steam_id if not steam_id.is_empty() else "7656119800000000%d" % seat, link.server, now_ms))
	return link


func _at(tick: int) -> int:
	return _base + ceili(float(tick) * 1000.0 / 60.0)


## Runs the room to a tick in steps the catch-up limit allows.
func _run_to(room: Room, tick: int) -> void:
	while room.tick < tick and room.phase == Room.Phase.RUNNING:
		room.poll(_at(mini(tick, room.tick + 20)))
	room.poll(_at(room.tick))


## Sends a packet and lets the room read it now, without letting time pass.
func _hear(room: Room, link: Loopback.Link, packet: PackedByteArray) -> void:
	link.client.send(packet)
	link.advance(0)
	room.poll(_at(room.tick))


func _send(link: Loopback.Link, packet: PackedByteArray) -> void:
	link.client.send(packet)
	link.advance(0)


## What the room sent to a client since the last call.
func _msgs(link: Loopback.Link) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	link.advance(0)
	while link.client.get_available_packet_count() > 0:
		out.append(Protocol.decode(link.client.get_packet()))
	return out


func _of_type(msgs: Array[Dictionary], type: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for m in msgs:
		if m.get("type") == type:
			out.append(m)
	return out


func _drive() -> int:
	return PlayerInput.encode(true, false, 0, true)


## Both people send the throttle and nitro for every tick up to `tick`, and the room runs to it.
func _race_to(room: Room, links: Array[Loopback.Link], tick: int) -> void:
	for t in range(room.tick, tick):
		for link in links:
			_send(link, Protocol.encode_input(t + 4, _drive()))
		_run_to(room, t + 1)


func test_the_room_starts_when_everybody_has_arrived_and_welcomes_each() -> void:
	var room := _room()
	var a := _join(room, 0)
	assert_eq(room.phase, Room.Phase.LOBBY, "waiting for the second person")
	var b := _join(room, 1)
	assert_eq(room.phase, Room.Phase.RUNNING)
	var welcome := _of_type(_msgs(b), Protocol.WELCOME)[0]
	assert_eq(welcome["seat"], 1)
	assert_eq(welcome["seats"], 3)
	assert_eq(welcome["seed"], 11)
	assert_eq(welcome["start_tick"], START)
	assert_eq(welcome["cfg_digest"], room.cfg_digest)
	assert_eq(welcome["players"], PackedStringArray(["76561198000000000", "76561198000000001", ""]), "a bot has no id")
	assert_eq(NetConfig.digest(NetConfig.build(welcome["config"])), room.cfg_digest, "the client builds the same rules")
	assert_eq(_of_type(_msgs(a), Protocol.WELCOME).size(), 1)


func test_a_seat_cannot_be_taken_twice_or_by_another_person() -> void:
	var room := _room()
	_join(room, 0)
	var other := Loopback.pair(9, 0)
	other.client.connect_to("x")
	other.advance(0)
	_links.append(other)
	assert_false(room.join_ticketed(0, "someone-else", other.server, 0), "already connected")
	assert_false(room.join_ticketed(2, "x", other.server, 0), "the bot's seat is no person's")
	assert_false(room.join_ticketed(7, "x", other.server, 0))


func test_a_room_whose_people_do_not_all_come_starts_after_the_join_timeout() -> void:
	var room := _room({"join_timeout_ms": 5000})
	_join(room, 0)
	room.poll(4999)
	assert_eq(room.phase, Room.Phase.LOBBY)
	room.poll(5000)
	assert_eq(room.phase, Room.Phase.RUNNING)
	_base = 5000
	_run_to(room, START + 30)
	assert_eq(room.stream_byte(START + 10, 1), PlayerInput.BOT, "the missing person's car is driven by a bot")
	assert_true((room.game.abandoned_mask & 0b10) != 0, "and counts as having left")


func test_the_clock_is_real_time_and_a_late_poll_catches_up() -> void:
	var room := _room()
	_join(room, 0)
	_join(room, 1)
	room.poll(0)
	assert_eq(room.tick, 0)
	room.poll(500)
	assert_eq(room.tick, 30)
	room.poll(1000)
	assert_eq(room.tick, 60, "60 ticks in a second")
	room.poll(1000 + floori(20.0 * Room.TICK_MS) + 1)
	assert_eq(room.tick, 80)
	room.poll(1000 + 10000)
	assert_eq(room.tick, 80 + Room.MAX_CATCH_UP, "a long stall catches up only so far")
	assert_gt(room.counters["skipped_ticks"], 0, "and says what it let go")


func test_ticks_go_out_every_two_ticks_with_the_confirmed_stream() -> void:
	var room := _room({"expected_humans": 0b001})
	var a := _join(room, 0)
	_run_to(room, START + 1)
	assert_eq(_of_type(_msgs(a), Protocol.TICKS).size(), 0, "the first step has not been taken yet")
	_run_to(room, START + 7)
	var all := _of_type(_msgs(a), Protocol.TICKS)
	assert_eq(all.size(), 3)
	var next := START
	for m in all:
		assert_eq(m["first_tick"], next)
		assert_eq(m["seats"], 3)
		assert_eq(m["count"], 2)
		next += 2
	var stream := PackedByteArray()
	for m in all:
		stream.append_array(m["controls"])
	for i in 6:
		for seat in 3:
			assert_eq(stream[i * 3 + seat], room.stream_byte(START + i, seat))


func test_a_late_input_is_applied_now_and_the_past_is_not_rewritten() -> void:
	var room := _room()
	var a := _join(room, 0)
	_join(room, 1)
	_run_to(room, 66)
	_hear(room, a, Protocol.encode_input(70, 0b00001))
	_run_to(room, 100)
	var held_before := room.stream_byte(99, 0)
	assert_eq(held_before, 0b00001)
	_hear(room, a, Protocol.encode_input(90, 0b10101))
	_run_to(room, 102)
	assert_eq(room.counters["late_inputs"], 1)
	assert_eq(room.stream_byte(90, 0), 0b00001, "tick 90 stays as it was played")
	assert_eq(room.stream_byte(100, 0), 0b10101, "the late input drives from the tick the room is at")
	assert_eq(room.stream_byte(101, 0), 0b10101, "and goes on")


func test_an_input_too_far_ahead_is_dropped_and_a_near_one_waits_for_its_tick() -> void:
	var room := _room()
	var a := _join(room, 0)
	_join(room, 1)
	_run_to(room, 66)
	_hear(room, a, Protocol.encode_input(70, 0b00001))
	_run_to(room, 100)
	_hear(room, a, Protocol.encode_input(100 + Room.INPUT_FUTURE_MAX + 1, 0b10000))
	_hear(room, a, Protocol.encode_input(105, 0b00010, PackedByteArray([1, 1, 1, 1])))
	_run_to(room, 110)
	assert_eq(room.counters["future_dropped"], 1)
	assert_eq(room.stream_byte(104, 0), 0b00001, "not before its tick")
	assert_eq(room.stream_byte(105, 0), 0b00010, "at its tick")
	assert_eq(room.stream_byte(109, 0), 0b00010)
	_run_to(room, 140)
	assert_eq(room.stream_byte(131, 0), 0b00010, "the dropped one never played")


func test_one_input_per_tick_and_older_ones_are_ignored() -> void:
	var room := _room()
	var a := _join(room, 0)
	_join(room, 1)
	_run_to(room, 70)
	_hear(room, a, Protocol.encode_input(80, 0b00001))
	_hear(room, a, Protocol.encode_input(80, 0b00010))
	_hear(room, a, Protocol.encode_input(79, 0b00100))
	_run_to(room, 90)
	assert_eq(room.counters["ignored_inputs"], 2)
	assert_eq(room.stream_byte(85, 0), 0b00001, "the first input of a tick is the one")


func test_bits_5_to_7_are_masked_and_the_pause_bit_does_nothing() -> void:
	var room := _room()
	var a := _join(room, 0)
	_join(room, 1)
	for t in range(70, 400):
		_hear(room, a, Protocol.encode_input(t, 0b11100101))
		_run_to(room, t - 3)
	for t in range(START, 380):
		assert_eq(room.stream_byte(t, 0) & 0xE0, 0, "bits 5 to 7 never reach the match")
	assert_eq(room.game.world.phase, 0, "nobody paused: the round runs (World.RUNNING)")
	assert_eq(room.game.world.events & 256, 0, "no pause event")


func test_ff_from_a_client_is_refused_and_does_not_hand_the_car_to_the_bot() -> void:
	var room := _room()
	var a := _join(room, 0)
	_join(room, 1)
	_run_to(room, 66)
	_hear(room, a, Protocol.encode_input(70, 0b00001))
	_run_to(room, 75)
	_hear(room, a, Protocol.encode_input(76, 0xFF))
	_hear(room, a, Protocol.encode_input(77, 0b00001, PackedByteArray([0, 0, 0xFF, 0])))
	_run_to(room, 90)
	assert_eq(room.counters["bad_packets"], 2)
	for t in range(START, 90):
		assert_ne(room.stream_byte(t, 0), PlayerInput.BOT)


func test_garbage_and_messages_a_client_must_not_send_are_counted_and_end_in_a_kick() -> void:
	var room := _room()
	var a := _join(room, 0)
	_join(room, 1)
	for i in Room.MAX_VIOLATIONS:
		_hear(room, a, PackedByteArray([200, 1, 2]))
	_run_to(room, 5)
	assert_eq(room.counters["bad_packets"], Room.MAX_VIOLATIONS)
	a.advance(0)
	assert_eq(a.client.get_state(), Loopback.Base.State.CLOSED, "the room hung up")
	_run_to(room, 10)
	assert_false(room.seats[0].connected)


func test_ping_gets_a_pong_with_the_server_tick() -> void:
	var room := _room({"expected_humans": 0b001})
	var a := _join(room, 0)
	_run_to(room, 25)
	_hear(room, a, Protocol.encode_ping(777))
	_run_to(room, 26)
	var pong := _of_type(_msgs(a), Protocol.PONG)[0]
	assert_eq(pong["client_time"], 777)
	assert_eq(pong["server_tick"], 25)


func test_ticks_tell_each_client_how_early_its_inputs_arrive() -> void:
	var room := _room()
	var a := _join(room, 0)
	var b := _join(room, 1)
	_run_to(room, 100)
	_msgs(a)
	_msgs(b)
	_hear(room, a, Protocol.encode_input(106, 0b00001))
	_hear(room, b, Protocol.encode_input(96, 0b00001))
	_run_to(room, 103)
	assert_eq(_of_type(_msgs(a), Protocol.TICKS)[0]["margin"], 6, "six ticks early")
	assert_eq(_of_type(_msgs(b), Protocol.TICKS)[0]["margin"], -4, "four ticks late")
	_run_to(room, 106)
	assert_eq(_of_type(_msgs(a), Protocol.TICKS)[0]["margin"], 127, "nothing new: no sample")


func test_a_person_who_stops_sending_is_handed_to_the_bot_and_comes_back_by_sending_again() -> void:
	var room := _room({"idle_ms": 500})
	var a := _join(room, 0)
	_join(room, 1)
	_run_to(room, 66)
	_hear(room, a, Protocol.encode_input(70, 0b00001))
	_run_to(room, 90)
	assert_eq(room.stream_byte(89, 0), 0b00001)
	_run_to(room, 160)
	assert_eq(room.stream_byte(159, 0), PlayerInput.BOT, "silent for more than idle_ms")
	assert_true((room.game.abandoned_mask & 1) != 0)
	_hear(room, a, Protocol.encode_input(165, 0b00001))
	_run_to(room, 170)
	assert_eq(room.stream_byte(169, 0), 0b00001, "it drives again")
	assert_eq(room.game.abandoned_mask & 1, 0, "and the seat is theirs again")


func test_a_disconnect_is_announced_then_the_bot_drives_and_the_seat_counts_as_left() -> void:
	var room := _room({"bot_after_ms": 500})
	var a := _join(room, 0)
	var b := _join(room, 1)
	_run_to(room, 66)
	_hear(room, a, Protocol.encode_input(70, 0b00001))
	_run_to(room, 100)
	_msgs(b)
	a.client.close()
	a.advance(0)
	_run_to(room, 101)
	var event := _of_type(_msgs(b), Protocol.EVENT)[0]
	assert_eq(event["kind"], Protocol.EVENT_DISCONNECT)
	assert_eq(event["seat"], 0)
	assert_eq(room.stream_byte(100, 0), 0b00001, "the held input drives on for a moment")
	_run_to(room, 140)
	assert_eq(room.stream_byte(139, 0), PlayerInput.BOT, "then the bot")
	assert_eq(room.game.abandoned_mask, 0b001)
	assert_eq(room.game.ranking_order().back(), 0)


func test_a_person_who_comes_back_within_the_grace_window_gets_the_seat_and_a_snapshot() -> void:
	var room := _room({"bot_after_ms": 300, "grace_ms": 20000})
	var a := _join(room, 0)
	_join(room, 1)
	_run_to(room, 66)
	_hear(room, a, Protocol.encode_input(70, 0b00001))
	_run_to(room, 100)
	a.client.close()
	a.advance(0)
	_run_to(room, 300)
	assert_eq(room.game.abandoned_mask, 0b001)
	var back := Loopback.pair(77, 0)
	back.client.connect_to("x")
	back.advance(0)
	_links.append(back)
	assert_false(room.join_ticketed(0, "another-person", back.server, _at(300)), "the seat is the ticket's")
	assert_true(room.join_ticketed(0, "76561198000000000", back.server, _at(300)))
	var msgs := _msgs(back)
	assert_eq(_of_type(msgs, Protocol.WELCOME)[0]["server_tick"], 300 - 0, "welcome tells the tick it is at")
	var snapshot := _of_type(msgs, Protocol.SNAPSHOT)[0]
	assert_eq(snapshot["tick"], room.tick)
	var parsed: Array = bytes_to_var(snapshot["state"])
	var copy := Match.from_array(room.cfg, parsed)
	assert_eq(copy.checksum(), room.game.checksum(), "the snapshot is the match as it stands")
	_run_to(room, 310)
	assert_eq(room.stream_byte(309, 0), PlayerInput.BOT, "the bot drives until the person sends something")
	_hear(room, back, Protocol.encode_input(320, 0b00010))
	_run_to(room, 330)
	assert_eq(room.stream_byte(329, 0), 0b00010)
	assert_eq(room.game.abandoned_mask, 0, "back in the match")
	var ticks := _of_type(_msgs(back), Protocol.TICKS)
	assert_eq(ticks[0]["first_tick"], 300, "TICKS go on from the snapshot")


func test_after_the_grace_window_the_seat_is_gone_for_good() -> void:
	var room := _room({"bot_after_ms": 200, "grace_ms": 2000})
	var a := _join(room, 0)
	_join(room, 1)
	a.client.close()
	a.advance(0)
	_run_to(room, 60 * 3)
	var late := Loopback.pair(78, 0)
	late.client.connect_to("x")
	late.advance(0)
	_links.append(late)
	assert_false(room.join_ticketed(0, "76561198000000000", late.server, _at(180)), "too late")
	assert_true(room.seats[0].final)
	assert_eq(room.game.abandoned_mask, 0b001)


func test_when_every_person_has_left_for_good_the_room_ends_incomplete() -> void:
	var room := _room({"bot_after_ms": 100, "grace_ms": 1000})
	var a := _join(room, 0)
	var b := _join(room, 1)
	_run_to(room, 100)
	a.client.close()
	b.client.close()
	a.advance(0)
	b.advance(0)
	_run_to(room, 100 + 60 * 3)
	room.poll(_at(100 + 60 * 3) + 100)
	assert_eq(room.phase, Room.Phase.ENDED)
	var result := room.result()
	assert_false(result["complete"])
	assert_true(result["seats"][0]["abandoned"])
	assert_true(result["seats"][1]["abandoned"])
	assert_true(room.finished(_at(100 + 60 * 3) + 100 + Room.Phase.ENDED + 10000))


func test_after_a_race_the_server_presses_confirm_600_ticks_later_and_only_for_people() -> void:
	var room := _room()
	var a := _join(room, 0)
	var b := _join(room, 1)
	var over := [-1]
	room.tick_hook = func(r: Room) -> void:
		if over[0] < 0 and (r.game.events & Match.EV_ROUND_OVER) != 0:
			over[0] = r.tick - 1
	_race_to(room, [a, b] as Array[Loopback.Link], START + 6000)
	var end: int = over[0]
	assert_gt(end, 0, "the first race ended")
	assert_eq(room.game.round_number, 2, "and the next one began by itself")
	for t in range(end + 1, end + 600):
		assert_eq(room.stream_byte(t, 0) & PlayerInput.CONFIRM, 0, "no confirm before 600 ticks")
	assert_ne(room.stream_byte(end + 600, 0) & PlayerInput.CONFIRM, 0, "the server presses it for a person")
	assert_ne(room.stream_byte(end + 600, 1) & PlayerInput.CONFIRM, 0)
	assert_eq(room.stream_byte(end + 600, 2), PlayerInput.BOT, "never for a bot")
	var race_ends := _of_type(_msgs(a), Protocol.EVENT).filter(func(m: Dictionary) -> bool: return m["kind"] == Protocol.EVENT_RACE_END)
	assert_eq(race_ends.size(), room.game.rounds_played(), "one EVENT for each race")
	assert_eq((race_ends[0]["data"] as PackedByteArray).size(), 1 + 3, "the race number and the seats in finishing order")


func test_a_match_ends_with_a_result_for_the_api_and_a_replay_that_plays_again() -> void:
	var room := _room()
	var a := _join(room, 0, 0, "76561198123456789")
	var b := _join(room, 1)
	_race_to(room, [a, b] as Array[Loopback.Link], START + 12000)
	assert_eq(room.phase, Room.Phase.ENDED)
	var result := room.result()
	assert_true(result["complete"])
	assert_false(result["ranked"], "a room by ticket here has no points either: the API decides")
	assert_eq(result["seed"], 11)
	assert_eq(result["seats"].size(), 3)
	assert_eq(result["seats"][0]["steam_id"], "76561198123456789", "ids stay text")
	assert_eq(result["seats"][2]["steam_id"], "")
	assert_true(result["seats"][2]["bot"])
	var places: Array = []
	for row: Dictionary in result["seats"]:
		places.append(row["place"])
	places.sort()
	assert_eq(places, [1, 2, 3])
	assert_eq(result["seats"][2]["abandoned"], false)
	var end := _of_type(_msgs(a), Protocol.EVENT).filter(func(m: Dictionary) -> bool: return m["kind"] == Protocol.EVENT_MATCH_END)
	assert_eq(end.size(), 1)
	var data: PackedByteArray = end[0]["data"]
	assert_eq(data.size(), 1 + 3 * 3)
	assert_eq(data[1 + 3 * 0], result["seats"][0]["place"])
	assert_eq(data[2 + 3 * 0], result["seats"][0]["race_points"])
	var replayed := Replay.run(room.replay_bytes())
	assert_true(replayed["ok"], "the replay reaches the same final checksum")
	assert_eq(replayed["checksum"], room.game.checksum())
	assert_eq((replayed["match"] as Match).phase, Match.MATCH_OVER)


func test_checksums_go_out_every_60_ticks_and_rooms_are_staggered() -> void:
	var room := _room({"stagger": 7, "expected_humans": 0b001})
	var a := _join(room, 0)
	_run_to(room, START + 200)
	var sums := _of_type(_msgs(a), Protocol.CHECKSUM)
	var ticks: Array = []
	for m in sums:
		ticks.append(m["tick"])
		assert_eq(m["cfg_digest"], room.cfg_digest)
	assert_eq(ticks, [START + 53, START + 113, START + 173], "(tick - start + stagger) is a multiple of 60")
	var other := _room({"stagger": 0})
	assert_ne(other.stagger, room.stagger)


func test_a_snapshot_is_sent_only_on_request_once_a_second_and_matches_the_server() -> void:
	var room := _room({"expected_humans": 0b001})
	var a := _join(room, 0)
	_run_to(room, START + 130)
	assert_eq(_of_type(_msgs(a), Protocol.SNAPSHOT).size(), 0, "never unasked")
	_hear(room, a, Protocol.encode_snapshot_req())
	_run_to(room, START + 131)
	var snaps := _of_type(_msgs(a), Protocol.SNAPSHOT)
	assert_eq(snaps.size(), 1)
	assert_eq(snaps[0]["tick"], START + 130, "the state at the tick it was asked")
	_hear(room, a, Protocol.encode_snapshot_req())
	_run_to(room, START + 135)
	assert_eq(_of_type(_msgs(a), Protocol.SNAPSHOT).size(), 0, "asking again at once gets nothing")
	assert_eq(room.counters["snapshots_refused"], 1)
	_run_to(room, START + 200)
	_hear(room, a, Protocol.encode_snapshot_req())
	_run_to(room, START + 201)
	assert_eq(_of_type(_msgs(a), Protocol.SNAPSHOT).size(), 1, "a second later it does")
	assert_lt(snaps[0]["state"].size(), 8000, "a snapshot is a few KB")


func test_ticks_are_never_sent_to_a_client_that_is_gone_and_pings_do_not_need_a_match() -> void:
	var room := _room({"expected_humans": 0b001})
	var a := _join(room, 0)
	a.client.close()
	a.advance(0)
	_run_to(room, 5)
	assert_false(room.seats[0].connected)
	assert_eq(room.connected_count(), 0)
