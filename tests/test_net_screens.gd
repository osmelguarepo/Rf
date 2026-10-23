extends "res://tests/test_case.gd"
## The ONLINE screen and the online race (scripts/app/online.gd, versus.gd with a session; docs/SPEC_ONLINE.md §16.4): from the
## title to a private room's lobby and into the race, over the loopback with a real host on a virtual clock. Each test boots a real
## App (tests/screen_helpers.gd).

const S := preload("res://tests/screen_helpers.gd")
const Harness := preload("res://tools/net_harness.gd")
const App := preload("res://scripts/app/app.gd")
const Online := preload("res://scripts/app/online.gd")
const OnlineSession := preload("res://scripts/net/online_session.gd")
const Loopback := preload("res://scripts/net/loopback_transport.gd")
const Transport := preload("res://scripts/net/transport.gd")
const RoomCode := preload("res://scripts/net/room_code.gd")
const Room := preload("res://scripts/server/room.gd")
const Nav := preload("res://scripts/input/nav.gd")
const World := preload("res://scripts/sim/world.gd")
const Match := preload("res://scripts/sim/match.gd")

var app: App
var h: Harness
var link: Loopback.Link = null
var accepted: bool = false


func before_each() -> void:
	app = S.boot(7)
	h = Harness.new({"tuning": {"race_finish_px": 1500.0, "match_races": 1}})
	h.host.seed_rng(5)
	link = null
	accepted = false
	app.online_clock = func() -> int: return h.now_ms
	app.online_transport_factory = _new_link


func after_each() -> void:
	app.online_clock = Callable()
	app.online_transport_factory = Callable()
	h.dispose()
	S.free_app(app)
	app = null
	h = null
	link = null


func _new_link() -> Transport:
	link = Loopback.pair(3, 30, 5)
	accepted = false
	return link.client


## Virtual time passes: the link, the host and the screen's frames.
func _pump(ms: int) -> void:
	var until := h.now_ms + ms
	while h.now_ms < until:
		h.now_ms += 17
		if link != null:
			link.advance(17)
			if not accepted and link.server.get_state() == Transport.State.OPEN:
				accepted = true
				h.host.accept(link.server, h.now_ms)
		h.host.poll(h.now_ms)
		S.frame(app, 0)


func _online() -> Online:
	app.show_online()
	return app.current_screen() as Online


func test_the_menu_moves_edits_the_name_and_the_code_and_goes_back_to_the_title() -> void:
	var screen := _online()
	assert_eq(screen.focus, Online.ROW_CREATE)
	screen.handle(Nav.UP)
	assert_eq(screen.focus, Online.ROW_NAME)
	screen.handle(Nav.ACCEPT)
	assert_true(screen.editing)
	screen.handle(Nav.UP)
	assert_eq(app.names.name_of(0), "P1B", "the same arcade editing as the join screen")
	screen.handle(Nav.RIGHT)
	screen.handle(Nav.ACCEPT)
	assert_false(screen.editing)
	for i in 3:
		screen.handle(Nav.DOWN)
	assert_eq(screen.focus, Online.ROW_CODE)
	screen.handle(Nav.ACCEPT)
	screen.handle(Nav.UP)
	assert_eq(screen.code_text, "A")
	screen.handle(Nav.UP)
	assert_eq(screen.code_text, "B")
	for i in 8:
		screen.handle(Nav.RIGHT)
	assert_eq(screen.code_text.length(), 6, "no more than six characters")
	screen.handle(Nav.LEFT)
	assert_eq(screen.code_text.length(), 5)
	screen.handle(Nav.ACCEPT)
	screen.handle(Nav.UP)
	screen.handle(Nav.UP)
	assert_eq(screen.focus, Online.ROW_CREATE)
	screen.handle(Nav.BACK)
	assert_eq(S.screen_name(app), "Title")


func test_joining_without_a_whole_code_says_so_and_does_not_connect() -> void:
	var screen := _online()
	screen.focus = Online.ROW_JOIN
	screen.handle(Nav.ACCEPT)
	assert_eq(screen.step, Online.Step.MENU)
	assert_true(screen.message.begins_with("TYPE THE 6"))
	assert_null(link, "no connection was made")


func test_creating_a_room_shows_its_lobby_and_the_owner_starts_the_race() -> void:
	var screen := _online()
	screen.handle(Nav.ACCEPT)
	assert_eq(screen.step, Online.Step.CONNECTING)
	_pump(600)
	assert_eq(screen.step, Online.Step.LOBBY)
	var code: String = screen.session.lobby["code"]
	assert_eq(code.length(), 6)
	assert_true(screen.session.lobby["owner"])
	assert_not_null(h.host.find(code))
	assert_eq(screen.session.lobby["names"][0], "P1", "the name from the join screen's names")
	# A friend joins by code through the same host.
	var friend := OnlineSession.new()
	var friend_link := Loopback.pair(8, 40)
	friend.connect_to(friend_link.client, "x", RoomCode.join_ticket(code, "BOB"))
	var friend_accepted := false
	var until := h.now_ms + 600
	while h.now_ms < until:
		h.now_ms += 17
		link.advance(17)
		friend_link.advance(17)
		if not friend_accepted and friend_link.server.get_state() == Transport.State.OPEN:
			friend_accepted = true
			h.host.accept(friend_link.server, h.now_ms)
		h.host.poll(h.now_ms)
		friend.update(h.now_ms)
		S.frame(app, 0)
	assert_eq(friend.state, OnlineSession.State.LOBBY)
	assert_eq((screen.session.lobby["names"] as PackedStringArray)[1], "BOB", "the owner sees who came")
	# Accept starts the match: the race opens with the server's seats.
	S.key_tap(app, KEY_ENTER)
	S.frame(app, 0)
	until = h.now_ms + 1500
	while h.now_ms < until and S.screen_name(app) != "Versus":
		h.now_ms += 17
		link.advance(17)
		friend_link.advance(17)
		h.host.poll(h.now_ms)
		friend.update(h.now_ms)
		S.frame(app, 0)
	assert_eq(S.screen_name(app), "Versus", "the race opened")
	friend.close()
	assert_not_null(app.online_session)
	assert_eq(app.online_session.seat, 0)
	var race := app.current_screen()
	assert_eq(race.session, app.online_session)
	assert_eq(race.lineup.size(), 6, "bots fill the empty seats")
	assert_eq((race.slot_names() as Array[String]).slice(0, 3), ["P1", "BOB", "BOT"] as Array[String])


func test_the_online_race_runs_on_the_session_and_leaving_goes_back_to_the_online_screen() -> void:
	var screen := _online()
	screen.handle(Nav.ACCEPT)
	_pump(600)
	assert_eq(screen.step, Online.Step.LOBBY)
	var code: String = screen.session.lobby["code"]
	S.key_tap(app, KEY_ENTER)
	_pump(300)
	assert_eq(S.screen_name(app), "Versus")
	var session := app.online_session
	var race := app.current_screen()
	_pump(12000)
	assert_eq(session.state, OnlineSession.State.PLAYING)
	assert_gt(session.rollback.confirmed_tick, 600, "the confirmed state follows the server")
	assert_eq(race.game_match, session.view_match())
	assert_eq(race.world, session.view_match().world)
	assert_gt(race.world.tick, 300)
	assert_eq(race.world.players.size(), 6)
	assert_eq(session.resyncs, 0)
	assert_has(app.audio.played, "beep_go", "the start gantry sounded, from the predicted ticks")
	assert_eq(app.audio.played.count("beep_go"), 1, "once")
	var room := h.host.find(code)
	assert_eq(room.phase, Room.Phase.RUNNING)
	assert_eq(session.confirmed_match().checksum().length(), 64)
	S.key_tap(app, KEY_ESCAPE)
	S.frame(app, 0)
	assert_eq(S.screen_name(app), "Online", "Esc leaves the match")
	assert_null(app.online_session)
	_pump(2500)
	assert_false(room.seats[0].connected, "and the server saw the person go")
	assert_true((room.game.abandoned_mask & 1) != 0 or room.phase == Room.Phase.ENDED)


func test_a_code_that_names_no_room_comes_back_as_a_message() -> void:
	var screen := _online()
	screen.code_text = "ABCDEF"
	screen.focus = Online.ROW_JOIN
	screen.handle(Nav.ACCEPT)
	_pump(600)
	assert_eq(screen.step, Online.Step.FAILED)
	assert_eq(screen.message, "NO ROOM WITH THAT CODE")
	screen.handle(Nav.ACCEPT)
	assert_eq(screen.step, Online.Step.MENU)
	assert_null(screen.session)


func test_a_server_that_cannot_be_reached_comes_back_as_a_message() -> void:
	app.online_transport_factory = func() -> Transport: return Transport.new()
	var screen := _online()
	screen.handle(Nav.ACCEPT)
	assert_eq(screen.step, Online.Step.FAILED)
	assert_eq(screen.message, "COULD NOT CONNECT")


func test_backing_out_of_a_lobby_leaves_the_room() -> void:
	var screen := _online()
	screen.handle(Nav.ACCEPT)
	_pump(600)
	var code: String = screen.session.lobby["code"]
	screen.handle(Nav.BACK)
	assert_eq(screen.step, Online.Step.MENU)
	_pump(500)
	assert_true(h.host.find(code) == null or h.host.find(code).connected_count() == 0)


func test_a_rollbacks_jump_is_eased_in_the_drawing_only() -> void:
	var screen := _online()
	screen.handle(Nav.ACCEPT)
	_pump(600)
	S.key_tap(app, KEY_ENTER)
	_pump(3000)
	assert_eq(S.screen_name(app), "Versus")
	var race := app.current_screen()
	var session := app.online_session
	var car_x: float = race.world.players[1].x
	var car_y: float = race.world.players[1].y_world
	session.add_view_offset(1, Vector2(12.0, 30.0))
	race.render()
	var drawn: World = race.cars.world
	assert_ne(drawn, race.world, "a copy is drawn while the jump fades")
	assert_eq(drawn.players[1].x, car_x + 12.0)
	assert_eq(drawn.players[1].y_world, car_y + 30.0)
	assert_eq(race.world.players[1].x, car_x, "the match itself is untouched")
	assert_eq(race.world.players[1].y_world, car_y)
	_pump(1000)
	assert_eq(session.view_offset(1), Vector2.ZERO, "and it fades away")
	assert_eq(race.cars.world, race.world, "then the world itself is drawn")
