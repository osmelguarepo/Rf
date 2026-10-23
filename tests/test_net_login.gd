extends "res://tests/test_case.gd"
## Logging in (scripts/net/login_flow.gd): the desktop Steam ticket flow, the web OpenID redirect and one-time code, guests, failures and
## the session token. Everything runs on fakes: an HTTP table, a Steam that answers, a page with a given URL fragment.

const ApiClient := preload("res://scripts/net/api_client.gd")
const Account := preload("res://scripts/net/account.gd")
const LoginFlow := preload("res://scripts/net/login_flow.gd")
const WebBridge := preload("res://scripts/net/web_bridge.gd")
const FakeHttp := preload("res://tests/fake_http.gd")
const FakeSteamAuth := preload("res://tests/fake_steam_auth.gd")
const FakeWeb := preload("res://tests/fake_web.gd")

const SESSION := {
	"token": "tok-abc", "expires_at": "2026-10-24T00:00:00Z",
	"profile": {"player_id": "7", "steam_id": "76561198000000001", "name": "RACER", "guest": false, "ranked": true, "points": 730,
		"division": 3, "division_name": "GOLD", "points_to_next": 70, "rank": 12, "provisional": false, "ranked_matches": 14},
}

var http: FakeHttp
var api: ApiClient
var account: Account
var steam: FakeSteamAuth
var web: FakeWeb


func before_each() -> void:
	http = FakeHttp.new()
	api = ApiClient.new(http, "https://play.example/api")
	account = Account.new()
	steam = FakeSteamAuth.new()
	web = FakeWeb.new(false)


func _flow(on_web: bool = false) -> LoginFlow:
	web = FakeWeb.new(on_web)
	return LoginFlow.new(api, account, steam, web)


func _settle(flow: LoginFlow, frames: int = 4) -> void:
	for i in frames:
		flow.poll()
		api.poll()


func test_the_desktop_flow_sends_the_steam_ticket_and_keeps_the_session_in_memory() -> void:
	http.on("POST", "/auth/steam", 200, SESSION)
	var flow := _flow()
	assert_true(flow.steam_possible())
	flow.start_steam()
	assert_eq(flow.state, LoginFlow.State.TICKET)
	assert_eq(steam.begun, 1)
	_settle(flow)
	assert_eq(FakeHttp.json_of(http.sent("POST", "/auth/steam")[0]), {"ticket": "deadbeef"})
	assert_eq(flow.state, LoginFlow.State.DONE)
	assert_true(flow.logged_in())
	assert_eq(api.token, "tok-abc")
	assert_eq(account.steam_id, "76561198000000001", "the SteamID stays text")
	assert_eq(account.points, 730)
	assert_eq(account.division_name, "GOLD")
	assert_eq(account.summary(), "RACER  GOLD  730")


func test_without_steam_there_is_no_steam_login_and_a_guest_is_offered() -> void:
	steam.running = false
	var flow := _flow()
	assert_false(flow.steam_possible())
	flow.start_steam()
	assert_eq(flow.state, LoginFlow.State.FAILED)
	assert_eq(flow.error, "steam_unavailable")
	http.on("POST", "/auth/guest", 200, {"token": "g-tok", "profile": {"player_id": "9", "name": "P1234", "guest": true, "ranked": false}})
	flow.start_guest()
	_settle(flow)
	assert_true(flow.logged_in())
	assert_true(account.guest)
	assert_false(account.ranked)
	assert_eq(account.summary(), "P1234  GUEST  NO POINTS")
	assert_eq(api.token, "g-tok")


func test_steam_not_answering_or_refusing_fails_without_calling_the_api() -> void:
	steam.answer = {"ok": false, "error": "STEAM REFUSED THE TICKET"}
	var flow := _flow()
	flow.start_steam()
	_settle(flow)
	assert_eq(flow.state, LoginFlow.State.FAILED)
	assert_eq(http.requests.size(), 0)
	assert_false(flow.logged_in())


func test_the_api_refusing_the_ticket_shows_why() -> void:
	http.on("POST", "/auth/steam", 403, {"error": "banned", "message": "x"})
	var flow := _flow()
	flow.start_steam()
	_settle(flow)
	assert_eq(flow.error, "banned")
	assert_eq(flow.message, "THIS ACCOUNT IS BANNED")
	assert_eq(api.token, "")


func test_an_unreachable_api_says_online_is_unavailable() -> void:
	var flow := _flow()
	flow.start_guest()
	_settle(flow)
	assert_eq(flow.error, "network")
	assert_eq(flow.message, "ONLINE UNAVAILABLE")


func test_on_the_web_the_steam_button_redirects_the_whole_page() -> void:
	var flow := _flow(true)
	assert_true(flow.steam_possible())
	flow.start_steam()
	assert_eq(flow.state, LoginFlow.State.REDIRECTING)
	assert_eq(web.navigated, ["https://play.example/api/auth/openid/start"])
	assert_eq(steam.begun, 0, "no Steam client in the browser")
	assert_eq(http.requests.size(), 0)


func test_coming_back_with_a_code_exchanges_it_and_cleans_the_address() -> void:
	http.on("POST", "/auth/exchange", 200, SESSION)
	var flow := _flow(true)
	web.page_fragment = "#code=ONE-TIME_code123"
	assert_true(flow.resume_from_url())
	assert_eq(web.cleaned, 1, "history.replaceState removes the code from the address bar")
	assert_eq(web.fragment(), "")
	assert_eq(FakeHttp.json_of(http.sent("POST", "/auth/exchange")[0]), {"code": "ONE-TIME_code123"})
	_settle(flow)
	assert_true(flow.logged_in())
	assert_eq(api.token, "tok-abc")
	assert_eq(account.player_name, "RACER")


func test_a_login_error_in_the_fragment_is_shown_and_cleaned() -> void:
	var flow := _flow(true)
	web.page_fragment = "#login_error=state_mismatch"
	assert_true(flow.resume_from_url())
	assert_eq(flow.state, LoginFlow.State.FAILED)
	assert_eq(flow.message, "LOGIN EXPIRED - TRY AGAIN")
	assert_eq(web.cleaned, 1)
	assert_eq(http.requests.size(), 0)


func test_a_page_with_nothing_for_us_is_left_alone() -> void:
	var flow := _flow(true)
	web.page_fragment = "#section"
	assert_false(flow.resume_from_url())
	assert_eq(web.cleaned, 0)
	var desktop := _flow(false)
	assert_false(desktop.resume_from_url())


func test_the_fragment_parser() -> void:
	assert_eq(WebBridge.parse_fragment("#code=abc&x=y%20z"), {"code": "abc", "x": "y z"})
	assert_eq(WebBridge.parse_fragment(""), {})
	assert_eq(WebBridge.parse_fragment("#"), {})
	assert_eq(WebBridge.parse_fragment("#=1&a"), {})


func test_logging_out_forgets_the_session_and_tells_the_api() -> void:
	http.on("POST", "/auth/guest", 200, SESSION)
	http.on("POST", "/auth/logout", 200, {})
	var flow := _flow()
	flow.start_guest()
	_settle(flow)
	assert_true(flow.logged_in())
	flow.logout()
	assert_false(flow.logged_in())
	assert_eq(api.token, "")
	assert_eq(http.sent("POST", "/auth/logout").size(), 1)
	assert_eq(FakeHttp.header_of(http.sent("POST", "/auth/logout")[0], "Authorization"), "Bearer tok-abc")


func test_refreshing_the_profile_updates_the_points_and_an_expired_session_logs_out() -> void:
	http.on("POST", "/auth/guest", 200, SESSION)
	http.on("GET", "/me", 200, {"player_id": "7", "name": "RACER", "ranked": true, "points": 760, "division_name": "GOLD", "ranked_matches": 15})
	var flow := _flow()
	flow.start_guest()
	_settle(flow)
	flow.refresh_profile()
	_settle(flow)
	assert_eq(account.points, 760)
	assert_eq(account.matches, 15)
	http.set_route("GET", "/me", 401, {"error": "unauthorized"})
	flow.refresh_profile()
	_settle(flow)
	assert_false(flow.logged_in())
	assert_eq(flow.error, "session_expired")


func test_a_response_without_a_token_is_not_a_login() -> void:
	http.on("POST", "/auth/guest", 200, {"profile": {"name": "X"}})
	var flow := _flow()
	flow.start_guest()
	_settle(flow)
	assert_false(flow.logged_in())
	assert_eq(flow.state, LoginFlow.State.FAILED)


func test_a_second_start_while_one_runs_is_ignored() -> void:
	var flow := _flow()
	flow.start_steam()
	flow.start_steam()
	flow.start_guest()
	assert_eq(steam.begun, 1)
	assert_eq(http.requests.size(), 0)
