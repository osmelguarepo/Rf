extends "res://tests/test_case.gd"
## The game server with the API's tickets (scripts/server/host.gd + room.gd + match_ticket.gd; docs/SPEC_ONLINE.md §16.2): a room is
## created by the first valid ticket, takes the other humans as their tickets arrive and starts when six are there or the gather window
## has passed; an expired ticket cannot open a room but brings a seated person back; the stand-in tickets are refused outside --dev; a
## draining server takes no new match; a hidden web tab hands its seat to the bot and gets the match back.

const Host := preload("res://scripts/server/host.gd")
const Room := preload("res://scripts/server/room.gd")
const MatchTicket := preload("res://scripts/net/match_ticket.gd")
const Ticket := preload("res://scripts/net/ticket.gd")
const Loopback := preload("res://scripts/net/loopback_transport.gd")
const Protocol := preload("res://scripts/net/protocol.gd")
const NetConfig := preload("res://scripts/net/net_config.gd")
const Outbox := preload("res://scripts/server/outbox.gd")

const KEY_HEX := "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
const NOW := 1800000000

var host: Host
var now_ms: int = 0
var unix: int = NOW
var links: Array[Loopback.Link] = []


func before_each() -> void:
	host = Host.new()
	host.seed_rng(3)
	host.match_verifier = MatchTicket.new(KEY_HEX, "srv1")
	host.legacy_enabled = false
	host.unix_clock = _unix
	now_ms = 0
	unix = NOW
	links = []


func after_each() -> void:
	host.unix_clock = Callable()


func _unix() -> int:
	return unix


func _fields(seat: int, player: String = "", extra: Dictionary = {}) -> Dictionary:
	var out := {
		"guest": false, "seat": seat, "seed": 1234567890123, "expires": NOW + 60, "server_id": "srv1", "match_id": "42",
		"player_id": player if not player.is_empty() else str(100 + seat), "steam_id": "7656119800000%04d" % seat,
		"name": "RACER%d" % seat,
	}
	out.merge(extra, true)
	return out


func _ticket(seat: int, player: String = "", extra: Dictionary = {}) -> String:
	return MatchTicket.issue(KEY_HEX.hex_decode(), _fields(seat, player, extra))


func _connect(ticket: String) -> Loopback.Link:
	var link := Loopback.pair(links.size() + 1, 0)
	link.client.connect_to("x")
	link.advance(0)
	links.append(link)
	host.accept(link.server, now_ms)
	link.client.send(Protocol.encode_hello("test", NetConfig.sim_hash(), ticket))
	link.advance(0)
	_run(1)
	return link


func _run(ms: int) -> void:
	var until := now_ms + ms
	while now_ms < until:
		now_ms += 1
		host.poll(now_ms)
	for link in links:
		link.advance(0)


func _heard(link: Loopback.Link) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	while link.client.get_available_packet_count() > 0:
		out.append(Protocol.decode(link.client.get_packet()))
	return out


func _of_type(msgs: Array[Dictionary], type: int) -> Array[Dictionary]:
	return msgs.filter(func(m: Dictionary) -> bool: return m.get("type") == type)


func _reject_reason(msgs: Array[Dictionary]) -> String:
	for m in _of_type(msgs, Protocol.EVENT):
		if m["kind"] == Protocol.EVENT_REJECT:
			return (m["data"] as PackedByteArray).get_string_from_ascii()
	return ""


func test_the_first_valid_ticket_makes_a_room_and_the_others_join_it() -> void:
	var a := _connect(_ticket(0))
	var room := host.find("42")
	assert_not_null(room)
	assert_true(room.open_humans)
	assert_eq(room.seat_count, 6, "the rest are bots")
	assert_eq(room.seed_value, 1234567890123)
	assert_eq(room.phase, Room.Phase.LOBBY, "alone, the room waits for the others")
	var b := _connect(_ticket(3))
	assert_eq(host.rooms.size(), 1)
	assert_eq(room.humans_mask(), 0b001001)
	assert_eq(room.seats[3].player_id, "103")
	assert_eq(room.seats[3].steam_id, "76561198000000003")
	assert_eq(_reject_reason(_heard(a)), "")
	assert_eq(_reject_reason(_heard(b)), "")


func test_the_match_starts_when_the_gather_window_passes() -> void:
	var a := _connect(_ticket(0))
	var b := _connect(_ticket(1))
	_run(Room.PREROLL_TICKS)
	assert_eq(host.find("42").phase, Room.Phase.LOBBY)
	_run(6100)
	var room := host.find("42")
	assert_eq(room.phase, Room.Phase.RUNNING)
	var welcome := _of_type(_heard(a), Protocol.WELCOME)
	assert_eq(welcome.size(), 1)
	assert_eq(welcome[0]["seat"], 0)
	assert_eq(welcome[0]["seed"], 1234567890123)
	assert_eq(welcome[0]["seats"], 6)
	assert_eq((welcome[0]["players"] as PackedStringArray)[1], "RACER1", "the others see names, not SteamIDs")
	assert_eq((welcome[0]["players"] as PackedStringArray)[2], "", "a bot")
	assert_eq(_of_type(_heard(b), Protocol.WELCOME).size(), 1)


func test_six_people_start_at_once() -> void:
	for seat in 6:
		_connect(_ticket(seat))
	assert_eq(host.find("42").phase, Room.Phase.RUNNING)


func test_a_ticket_for_another_server_or_a_forged_one_is_turned_away() -> void:
	var other := _connect(_ticket(0, "", {"server_id": "srv2"}))
	assert_eq(_reject_reason(_heard(other)), MatchTicket.ERR_SERVER)
	var forged := _connect(MatchTicket.issue("ff".repeat(32).hex_decode(), _fields(0)))
	assert_eq(_reject_reason(_heard(forged)), MatchTicket.ERR_SIGNATURE)
	var junk := _connect("AAAA")
	assert_eq(_reject_reason(_heard(junk)), MatchTicket.ERR_FORMAT)
	assert_eq(host.rooms.size(), 0)


func test_the_same_seat_cannot_be_taken_twice() -> void:
	var a := _connect(_ticket(0))
	var again := _connect(_ticket(0))
	assert_eq(_reject_reason(_heard(again)), Host.REJECT_SEAT)
	assert_eq(_reject_reason(_heard(a)), "")


func test_an_expired_ticket_cannot_open_a_room() -> void:
	unix = NOW + 61
	var late := _connect(_ticket(0))
	assert_eq(_reject_reason(_heard(late)), MatchTicket.ERR_EXPIRED)
	assert_eq(host.rooms.size(), 0)


func test_a_seated_person_comes_back_with_an_expired_ticket_but_nobody_else_does() -> void:
	var mine := _ticket(1)
	var a := _connect(_ticket(0))
	var b := _connect(mine)
	_run(6100)
	assert_eq(host.find("42").phase, Room.Phase.RUNNING)
	b.client.close()
	b.advance(0)
	_run(200)
	unix = NOW + 90
	var back := _connect(mine)
	var heard := _heard(back)
	assert_eq(_reject_reason(heard), "", "the same person and seat: let in")
	assert_eq(_of_type(heard, Protocol.WELCOME).size(), 1, "with the whole match again")
	var stranger := _connect(_ticket(1, "999"))
	assert_eq(_reject_reason(_heard(stranger)), MatchTicket.ERR_EXPIRED, "another player's old ticket for that seat")
	var newcomer := _connect(_ticket(4))
	assert_eq(_reject_reason(_heard(newcomer)), MatchTicket.ERR_EXPIRED, "a seat nobody took")
	assert_eq(_reject_reason(_heard(a)), "")


func test_the_stand_in_tickets_are_refused_unless_the_server_is_in_dev_mode() -> void:
	var dev := Ticket.issue_dev("dev-match", 0, "76561198123456789", 5, 6, 0b000001)
	var link := _connect(dev)
	assert_eq(_reject_reason(_heard(link)), Ticket.ERR_FORMAT)
	host.legacy_enabled = true
	host.verifier = Ticket.new("", true)
	var allowed := _connect(dev)
	assert_eq(_reject_reason(_heard(allowed)), "")
	assert_not_null(host.find("dev-match"))


func test_a_draining_server_takes_no_new_match_but_keeps_its_own() -> void:
	var a := _connect(_ticket(0))
	host.draining = true
	var late_seat := _connect(_ticket(1))
	assert_eq(_reject_reason(_heard(late_seat)), "", "a seat of a match under way still joins")
	var new_match := _connect(_ticket(0, "", {"match_id": "43"}))
	assert_eq(_reject_reason(_heard(new_match)), Host.REJECT_DRAINING)
	assert_eq(host.active_matches(), 1)
	assert_eq(_reject_reason(_heard(a)), "")


func test_a_hidden_tab_hands_the_seat_to_the_bot_and_coming_back_resends_the_match() -> void:
	var a := _connect(_ticket(0))
	var b := _connect(_ticket(1))
	_run(6100)
	var room := host.find("42")
	_run(1300)
	_heard(a)
	_heard(b)
	a.client.send(Protocol.encode_input(room.tick + 2, 0b00001))
	a.advance(0)
	_run(20)
	assert_false(room.seats[0].awaiting_input)
	a.client.send(Protocol.encode_away(true))
	a.advance(0)
	_run(20)
	assert_true(room.seats[0].awaiting_input, "the bot drives while the tab is hidden")
	assert_eq(room.counters.get("away_hidden", 0), 1)
	assert_eq(room._byte_of(room.seats[0], now_ms), 0xFF)
	_heard(a)
	a.client.send(Protocol.encode_away(false))
	a.advance(0)
	_run(20)
	var got := _heard(a)
	assert_eq(_of_type(got, Protocol.WELCOME).size(), 1, "back: the whole match again")
	assert_eq(_of_type(got, Protocol.SNAPSHOT).size(), 1)
	assert_eq(room.counters.get("away_back", 0), 1)
	assert_true(room.seats[0].awaiting_input, "and the bot drives until its first input")


func test_a_finished_match_gives_the_api_the_places_of_the_people_and_nothing_else() -> void:
	var a := _connect(_ticket(0))
	var b := _connect(_ticket(1, "", {"guest": true, "steam_id": "", "name": ""}))
	assert_not_null(a)
	assert_not_null(b)
	_run(6100)
	var room := host.find("42")
	assert_eq(room.seats[1].guest, true)
	assert_eq(room.seats[1].label, "P2", "a guest without a name is called by its seat")
	var result := room.result()
	assert_eq(result["seats"][0]["player_id"], "100")
	var body := Outbox.result_body(result)
	assert_eq(body["players"].size(), 2, "the people, not the four bots")
	assert_eq(body["players"][0]["player_id"], "100", "ids as text")
	assert_has(body["players"][0], "place")
	assert_has(body["players"][0], "abandoned")
	assert_eq((body["players"][0] as Dictionary).keys().size(), 3, "no points, no SteamID")
	assert_true(Outbox.result_body({"private": true, "seats": result["seats"]}).is_empty(), "private rooms report nothing")
	assert_true(Outbox.result_body({"seats": [{"bot": false, "player_id": "", "place": 1, "abandoned": false}]}).is_empty(), "dev tickets either")
