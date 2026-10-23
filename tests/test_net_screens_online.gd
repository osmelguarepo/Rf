extends "res://tests/test_case.gd"
## The login screen, the queue screen and everything they hand over to the race (docs/SPEC_ONLINE.md §16.4, §16.5; M4/M5), on a real
## App with fakes: an HTTP table for the API, a Steam that answers, a page that is or is not the web, and a real host over the
## loopback with a virtual clock for the game server.

const S := preload("res://tests/screen_helpers.gd")
const Harness := preload("res://tools/net_harness.gd")
const App := preload("res://scripts/app/app.gd")
const Title := preload("res://scripts/app/title.gd")
const Login := preload("res://scripts/app/login_screen.gd")
const Queue := preload("res://scripts/app/queue_screen.gd")
const Matchmaking := preload("res://scripts/net/matchmaking.gd")
const OnlineSession := preload("res://scripts/net/online_session.gd")
const ApiClient := preload("res://scripts/net/api_client.gd")
const Loopback := preload("res://scripts/net/loopback_transport.gd")
const Transport := preload("res://scripts/net/transport.gd")
const Room := preload("res://scripts/server/room.gd")
const Nav := preload("res://scripts/input/nav.gd")
const RankingView := preload("res://scripts/view/ranking_view.gd")
const FakeHttp := preload("res://tests/fake_http.gd")
const FakeSteamAuth := preload("res://tests/fake_steam_auth.gd")
const FakeWeb := preload("res://tests/fake_web.gd")

const MATCH := "9007199254740993"
const SESSION := {
	"token": "tok-abc",
	"profile": {"player_id": "7", "steam_id": "76561198000000001", "name": "RACER", "guest": false, "ranked": true, "points": 730,
		"division": 3, "division_name": "GOLD", "ranked_matches": 14},
}

var app: App
var h: Harness
var http: FakeHttp
var steam: FakeSteamAuth
var web: FakeWeb
var link: Loopback.Link = null
var accepted: bool = false
var unix: int = 1000


func before_each() -> void:
	app = S.boot(7)
	h = Harness.new({"tuning": {"race_finish_px": 1500.0, "match_races": 1}, "humans": 0b000001})
	h.host.seed_rng(5)
	http = FakeHttp.new()
	steam = FakeSteamAuth.new()
	web = FakeWeb.new(false)
	link = null
	accepted = false
	unix = 1000
	app.online_clock = func() -> int: return h.now_ms
	app.unix_clock = func() -> int: return unix
	app.online_transport_factory = _new_link
	app.use_online(ApiClient.new(http, "https://play.example/api"), steam, web)
	http.on("GET", "/healthz", 200, {"ok": true})
	http.on("POST", "/queue", 200, {"queue_id": "1"})
	http.on("DELETE", "/queue", 200, {})
	http.on("POST", "/queue/ready", 200, {})
	http.on("POST", "/auth/guest", 200, SESSION)
	http.on("POST", "/auth/steam", 200, SESSION)
	http.on("GET", "/me", 200, SESSION["profile"])
	http.on("POST", "/match/%s/leave" % MATCH, 200, {})


func after_each() -> void:
	app.online_clock = Callable()
	app.unix_clock = Callable()
	app.online_transport_factory = Callable()
	app.api.drop_pending()
	h.dispose()
	S.free_app(app)
	app = null
	h = null
	link = null


func _new_link() -> Transport:
	link = Loopback.pair(3, 30, 5)
	accepted = false
	return link.client


## Virtual time passes: the API answers, the link, the host and the screen's frames.
func _pump(ms: int) -> void:
	var until := h.now_ms + ms
	while h.now_ms < until:
		h.now_ms += 17
		app.api.poll()
		app.login.poll()
		if link != null:
			link.advance(17)
			if not accepted and link.server.get_state() == Transport.State.OPEN:
				accepted = true
				h.host.accept(link.server, h.now_ms)
		h.host.poll(h.now_ms)
		S.frame(app, 0)


func _login_as_guest() -> void:
	app.login.start_guest()
	_pump(100)
	assert_true(app.login.logged_in())


func _queue() -> Queue:
	_login_as_guest()
	app.show_queue()
	return app.current_screen() as Queue


## The API knows this player as a guest: no points.
func _guest_account() -> void:
	var guest := {"player_id": "9", "name": "P1234", "guest": true, "ranked": false}
	http.set_route("POST", "/auth/guest", 200, {"token": "g", "profile": guest})
	http.set_route("GET", "/me", 200, guest)


## Time passes for the server and the link only: the page's frames do not run (a hidden tab).
func _pump_server_only(ms: int) -> void:
	var until := h.now_ms + ms
	while h.now_ms < until:
		h.now_ms += 17
		if link != null:
			link.advance(17)
		h.host.poll(h.now_ms)


func _status(state: String, extra: Dictionary = {}) -> Dictionary:
	var body := {"state": state, "wait_s": 3, "band_divisions": 1, "players_found": 2}
	body.merge(extra, true)
	return body


## Finds a race and plays the API's part up to the connection: waiting, found, accepted, starting.
func _find_race_and_start(screen: Queue) -> void:
	screen.handle(Nav.ACCEPT)
	assert_eq(screen.step, Queue.Step.SEARCHING)
	http.on("GET", "/queue/status", 200, _status("waiting"))
	_pump(900)
	assert_eq(screen.mm.state, Matchmaking.State.WAITING)
	http.set_route("GET", "/queue/status", 200, _status("found", {"match": {"match_id": MATCH, "ready_deadline_unix": 1020}}))
	_pump(1200)
	assert_eq(screen.mm.state, Matchmaking.State.FOUND)
	screen.handle(Nav.ACCEPT)
	_pump(100)
	http.set_route("GET", "/queue/status", 200, _status("starting", {"match": {"match_id": MATCH, "ready_deadline_unix": 1020}}))
	http.on("GET", "/match/%s/join" % MATCH, 200, {"ws_url": "ws://127.0.0.1:9080", "ticket": h.ticket_for(0, "76561198000000001")})
	_pump(1500)


# --- Entering and logging in ------------------------------------------------------------------------------------------------


func test_online_on_the_title_opens_the_login_then_the_queue_and_without_an_api_the_private_rooms() -> void:
	app.show_title()
	app.current_screen().select(Title.CHOICE_ONLINE)
	app.current_screen().start()
	assert_eq(S.screen_name(app), "Login")
	_login_as_guest()
	app.show_title()
	app.current_screen().start()
	assert_eq(S.screen_name(app), "Queue", "already logged in: straight to the queue")
	var bare := S.boot(8)
	bare.show_title()
	bare.current_screen().select(Title.CHOICE_ONLINE)
	bare.current_screen().start()
	assert_eq(S.screen_name(bare), "Online", "no API: the private rooms, as before")
	S.free_app(bare)


func test_the_login_screen_offers_steam_a_guest_and_the_private_rooms() -> void:
	app.show_login()
	var screen := app.current_screen() as Login
	assert_eq(screen.rows(), [Login.ROW_STEAM, Login.ROW_GUEST, Login.ROW_ROOMS] as Array[String])
	steam.running = false
	assert_eq(screen.rows(), [Login.ROW_GUEST, Login.ROW_ROOMS] as Array[String], "no Steam running: no Steam login")
	screen.handle(Nav.BACK)
	assert_eq(S.screen_name(app), "Title")


func test_logging_in_with_steam_goes_on_to_the_queue() -> void:
	app.show_login()
	var screen := app.current_screen() as Login
	screen.handle(Nav.ACCEPT)
	assert_eq(steam.begun, 1)
	assert_true(app.login.busy())
	_pump(200)
	assert_eq(S.screen_name(app), "Queue")
	assert_eq(app.account.points, 730)
	assert_eq(app.api.token, "tok-abc")


func test_a_guest_login_goes_on_to_the_queue_without_points() -> void:
	_guest_account()
	app.show_login()
	var screen := app.current_screen() as Login
	screen.handle(Nav.DOWN)
	screen.handle(Nav.ACCEPT)
	_pump(200)
	assert_eq(S.screen_name(app), "Queue")
	assert_eq(app.account.summary(), "P1234  GUEST  NO POINTS")


func test_a_refused_login_shows_why_and_a_dead_api_offers_to_play_local() -> void:
	http.set_route("POST", "/auth/steam", 403, {"error": "banned"})
	app.show_login()
	var screen := app.current_screen() as Login
	screen.handle(Nav.ACCEPT)
	_pump(200)
	assert_eq(S.screen_name(app), "Login")
	assert_eq(screen.message, "THIS ACCOUNT IS BANNED")
	assert_false(screen.rows().has(Login.ROW_LOCAL))
	http.routes = []
	screen.focus = 1
	screen.handle(Nav.ACCEPT)
	_pump(200)
	assert_eq(screen.message, "ONLINE UNAVAILABLE")
	assert_true(screen.rows().has(Login.ROW_LOCAL), "the way back to the local game")
	screen.focus = screen.rows().find(Login.ROW_LOCAL)
	screen.handle(Nav.ACCEPT)
	assert_eq(S.screen_name(app), "Join")


func test_the_web_login_redirects_and_the_page_that_comes_back_logs_in() -> void:
	web = FakeWeb.new(true)
	app.use_online(ApiClient.new(http, "https://play.example/api"), steam, web)
	http.on("POST", "/auth/exchange", 200, SESSION)
	app.show_login()
	var screen := app.current_screen() as Login
	assert_eq(screen.rows()[0], Login.ROW_STEAM)
	screen.handle(Nav.ACCEPT)
	assert_eq(web.navigated, ["https://play.example/api/auth/openid/start"])
	assert_eq(steam.begun, 0)
	# The page is loaded again with the code in its address.
	var fresh := FakeWeb.new(true)
	fresh.page_fragment = "#code=abc123"
	app.use_online(ApiClient.new(http, "https://play.example/api"), steam, fresh)
	assert_true(app.login.resume_from_url())
	_pump(200)
	assert_true(app.login.logged_in())
	assert_eq(fresh.cleaned, 1)
	app.show_title()
	app.current_screen().select(Title.CHOICE_ONLINE)
	app.current_screen().start()
	assert_eq(S.screen_name(app), "Queue")


# --- The queue ---------------------------------------------------------------------------------------------------------------


func test_the_queue_menu_moves_and_its_rows_lead_to_the_other_screens() -> void:
	var screen := _queue()
	assert_eq(screen.focus, Queue.ROW_FIND)
	screen.handle(Nav.DOWN)
	screen.handle(Nav.ACCEPT)
	assert_eq(S.screen_name(app), "Online", "private rooms")
	app.show_queue()
	screen = app.current_screen() as Queue
	screen.focus = Queue.ROW_RANKING
	screen.handle(Nav.ACCEPT)
	assert_eq(S.screen_name(app), "Ranking")
	assert_not_null(app.online_ranking, "logged in: the online store")
	app.show_queue()
	screen = app.current_screen() as Queue
	screen.focus = Queue.ROW_LOGOUT
	http.on("POST", "/auth/logout", 200, {})
	screen.handle(Nav.ACCEPT)
	assert_eq(S.screen_name(app), "Title")
	assert_false(app.login.logged_in())


func test_searching_shows_the_wait_the_band_and_the_players_and_back_cancels() -> void:
	var screen := _queue()
	screen.handle(Nav.ACCEPT)
	http.on("GET", "/queue/status", 200, _status("waiting", {"wait_s": 75, "band_divisions": 2, "players_found": 4}))
	_pump(900)
	var shown: Dictionary = screen.view.data
	assert_eq(shown["headline"], "SEARCHING FOR RIVALS")
	assert_eq(shown["lines"], ["TIME  1:15", "DIVISIONS  +/- 2", "PLAYERS FOUND  4"])
	assert_eq(shown["hints"], ["BACK / ESC  CANCEL"])
	screen.handle(Nav.BACK)
	assert_eq(screen.step, Queue.Step.MENU)
	assert_eq(screen.message, "LEFT THE QUEUE")
	_pump(100)
	assert_eq(http.sent("DELETE", "/queue").size(), 1)


func test_the_ready_check_counts_down_and_accepting_waits_for_the_others() -> void:
	var screen := _queue()
	screen.handle(Nav.ACCEPT)
	http.on("GET", "/queue/status", 200, _status("found", {"match": {"match_id": MATCH, "ready_deadline_unix": 1020}}))
	_pump(1500)
	assert_eq(screen.view.data["headline"], "MATCH FOUND")
	assert_eq(screen.view.data["lines"][1], "ACCEPT IN  20")
	unix = 1012
	_pump(100)
	assert_eq(screen.view.data["lines"][1], "ACCEPT IN  8")
	screen.handle(Nav.ACCEPT)
	_pump(100)
	assert_eq(FakeHttp.json_of(http.sent("POST", "/queue/ready")[0]), {"match_id": MATCH})
	assert_eq(screen.view.data["headline"], "WAITING FOR THE OTHERS")
	screen.handle(Nav.BACK)
	assert_eq(screen.step, Queue.Step.MENU, "a refusal leaves the queue")


func test_a_penalty_is_shown_and_dismissed() -> void:
	var screen := _queue()
	http.set_route("POST", "/queue", 429, {"error": "queue_penalty", "retry_after_s": 600})
	screen.handle(Nav.ACCEPT)
	_pump(500)
	assert_eq(screen.step, Queue.Step.FAILED)
	assert_eq(screen.message, "YOU LEFT TOO MANY MATCHES - WAIT 10 MIN")
	screen.handle(Nav.ACCEPT)
	assert_eq(screen.step, Queue.Step.MENU)


func test_a_dead_session_sends_the_player_back_to_the_login() -> void:
	var screen := _queue()
	http.set_route("POST", "/queue", 401, {"error": "unauthorized"})
	screen.handle(Nav.ACCEPT)
	_pump(500)
	assert_eq(screen.step, Queue.Step.FAILED)
	assert_false(app.login.logged_in())
	screen.handle(Nav.ACCEPT)
	assert_eq(S.screen_name(app), "Login")


func test_a_started_match_opens_the_websocket_and_the_race_with_the_api_ticket() -> void:
	var screen := _queue()
	_find_race_and_start(screen)
	assert_eq(S.screen_name(app), "Versus", "the race opened")
	assert_true(app.online_matchmade)
	assert_eq(app.online_match_id, MATCH)
	assert_not_null(app.online_session)
	assert_eq(app.online_session.seat, 0)
	assert_true(app.online_session.reconnect_factory.is_valid())
	var room := h.host.find("harness")
	assert_not_null(room)
	assert_eq(room.seats[0].steam_id, "76561198000000001")


func test_leaving_a_queue_match_tells_the_api_and_returns_to_the_queue_screen() -> void:
	var screen := _queue()
	_find_race_and_start(screen)
	_pump(1500)
	S.key_tap(app, KEY_ESCAPE)
	S.frame(app, 0)
	assert_eq(S.screen_name(app), "Queue")
	_pump(100)
	assert_eq(http.sent("POST", "/match/%s/leave" % MATCH).size(), 1)
	assert_null(app.online_session)


func test_an_old_game_version_is_told_to_update_and_on_the_web_to_reload() -> void:
	assert_eq(Queue.reason_text("version"), "UPDATE THE GAME")
	assert_eq(Queue.reason_text("sim_hash"), "UPDATE THE GAME")
	assert_eq(Queue.reason_text("sim_hash", true), "RELOAD THE PAGE TO UPDATE THE GAME")
	assert_eq(Queue.reason_text("expired"), "THE MATCH TICKET EXPIRED - TRY AGAIN")
	assert_eq(Queue.reason_text("full"), "THE ROOM IS FULL")
	assert_eq(Queue.reason_text("zzz"), "REFUSED: ZZZ")


func test_a_server_that_refuses_the_hello_shows_the_reason_and_leaves_the_match() -> void:
	var screen := _queue()
	h.host.legacy_enabled = false
	http.on("POST", "/match/%s/leave" % MATCH, 200, {})
	_find_race_and_start_with("garbage-ticket", screen)
	_pump(600)
	assert_eq(screen.step, Queue.Step.FAILED)
	assert_eq(screen.message, "THE SERVER REFUSED THE TICKET")
	assert_eq(http.sent("POST", "/match/%s/leave" % MATCH).size(), 1)


func _find_race_and_start_with(ticket: String, screen: Queue) -> void:
	screen.handle(Nav.ACCEPT)
	http.on("GET", "/queue/status", 200, _status("starting", {"match": {"match_id": MATCH, "ready_deadline_unix": 1020}}))
	http.on("GET", "/match/%s/join" % MATCH, 200, {"ws_url": "ws://127.0.0.1:9080", "ticket": ticket})
	_pump(2500)


# --- In the race -------------------------------------------------------------------------------------------------------------


func _race() -> Node:
	var screen := _queue()
	_find_race_and_start(screen)
	_pump(1500)
	assert_eq(S.screen_name(app), "Versus")
	return app.current_screen()


func test_a_lost_connection_is_made_again_within_the_grace_window_and_says_so() -> void:
	var race := _race()
	var session := app.online_session
	assert_eq(session.state, OnlineSession.State.PLAYING)
	link.server.close()
	_pump(100)
	assert_eq(session.state, OnlineSession.State.RECONNECTING)
	assert_true(race.hud.notice.begins_with("CONNECTION LOST\nRECONNECTING..."))
	assert_eq(S.screen_name(app), "Versus", "the race screen stays up")
	_pump(6000)
	assert_eq(session.reconnects, 1)
	assert_eq(session.state, OnlineSession.State.PLAYING, "welcomed again")
	assert_eq(race.hud.notice, "", "and the notice is gone")
	assert_eq(session.failure, "")
	var room := h.host.find("harness")
	assert_true(room.seats[0].connected)


func test_a_connection_that_never_comes_back_ends_the_race_with_a_message() -> void:
	var race := _race()
	var session := app.online_session
	session.reconnect_window_ms = 3000
	app.online_transport_factory = func() -> Transport: return Transport.new()
	link.server.close()
	_pump(6000)
	assert_eq(S.screen_name(app), "Queue")
	assert_null(app.online_session)
	assert_eq(race.session.failure, "disconnected")


func test_backing_out_while_reconnecting_leaves() -> void:
	var race := _race()
	app.online_transport_factory = func() -> Transport: return Transport.new()
	link.server.close()
	_pump(200)
	assert_eq(app.online_session.state, OnlineSession.State.RECONNECTING)
	assert_true(race.handle_online(Nav.KEYBOARD, Nav.BACK))
	assert_eq(S.screen_name(app), "Queue")


func test_a_hidden_tab_tells_the_server_and_coming_back_gets_the_match_again() -> void:
	web = FakeWeb.new(true)
	app.use_online(app.api, steam, web)
	web.watch_visibility(app.on_visibility_changed)
	_race()
	var room := h.host.find("harness")
	var session := app.online_session
	web.set_hidden(true)
	_pump_server_only(300)
	assert_eq(room.counters.get("away_hidden", 0), 1, "the server heard that the tab is hidden")
	assert_true(room.seats[0].awaiting_input, "and the bot drives")
	web.set_hidden(false)
	var welcomes_before := session.rollback.confirmed_tick
	_pump(600)
	assert_eq(room.counters.get("away_back", 0), 1)
	assert_eq(session.state, OnlineSession.State.PLAYING)
	assert_gt(session.rollback.confirmed_tick, welcomes_before)
	assert_false(room.seats[0].awaiting_input, "and the person drives again with the first input")


func test_the_visibility_message_is_only_for_a_session_in_play() -> void:
	web = FakeWeb.new(true)
	app.use_online(app.api, steam, web)
	web.watch_visibility(app.on_visibility_changed)
	web.set_hidden(true)
	web.set_hidden(false)
	assert_null(app.online_session, "nothing to tell")
	assert_eq(http.requests.size(), 0)


func test_after_a_queue_match_the_new_points_are_read_from_the_api() -> void:
	var race := _race()
	assert_false(race._profile_done, "a ranked player asks for the points after the match")
	assert_eq(race._points_before, 730)
	http.set_route("GET", "/me", 200, {"player_id": "7", "name": "RACER", "ranked": true, "points": 760, "ranked_matches": 15})
	race._profile_wait = 0.0
	race._follow_profile(0.1)
	app.api.poll()
	assert_true(race._profile_done)
	assert_eq(race.ranking_results[0]["before"], 730)
	assert_eq(race.ranking_results[0]["after"], 760)
	assert_eq(race.ranking_results[0]["delta"], 30)


func test_an_unchanged_profile_is_asked_again_a_few_times_then_dropped() -> void:
	var race := _race()
	for i in 12:
		race._profile_wait = 0.0
		race._follow_profile(0.1)
		app.api.poll()
	assert_true(race._profile_done)
	assert_true(race.ranking_results.is_empty())
	assert_eq(http.sent("GET", "/me").size(), 1 + 8, "the queue screen's refresh, then at most 8 tries")


func test_a_guest_does_not_wait_for_points() -> void:
	_guest_account()
	var race := _race()
	assert_true(race._profile_done)


# --- The online ranking ------------------------------------------------------------------------------------------------------


func test_the_ranking_screen_shows_the_online_leaderboard_when_logged_in_and_the_local_one_otherwise() -> void:
	http.on("GET", "/leaderboard?limit=%d" % RankingView.ROWS, 200, {"entries": [
		{"rank": 1, "player_id": "76561198000000001", "name": "ANA", "points": 1250, "division": 5, "division_name": "PLATINUM"},
		{"rank": 2, "player_id": "5", "name": "BOB", "points": 900, "division": 4, "division_name": "GOLD"},
	]})
	_login_as_guest()
	app.show_ranking()
	var screen := app.current_screen()
	assert_eq(screen.view.status, "LOADING...")
	assert_true(screen.view.records.is_empty())
	_pump(100)
	assert_eq(screen.view.records.size(), 2)
	assert_eq(screen.view.records[0], {"id": "76561198000000001", "name": "ANA", "points": 1250, "matches": 0, "rank": 1})
	assert_eq(screen.view.status, "")
	app.login.logout()
	app.show_ranking()
	assert_null(app.online_ranking, "logged out: the session's own ranking")


func test_an_unreachable_leaderboard_says_so() -> void:
	_login_as_guest()
	app.show_ranking()
	_pump(100)
	assert_eq(app.current_screen().view.status, "ONLINE RANKING UNAVAILABLE")
