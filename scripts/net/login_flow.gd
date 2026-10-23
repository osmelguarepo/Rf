extends RefCounted
## Logging in (docs/SPEC_ONLINE.md §4, §16.3, §16.5), as a state machine the screens read and tests drive with fakes:
##
## - Desktop with Steam: start_steam() asks Steam for a web-API ticket (steam_auth.gd), then POST /auth/steam {ticket}.
## - Web: start_steam() redirects the whole page to /auth/openid/start; Steam sends it back to the game with a one-time code in the
##   URL fragment (#code=...); resume_from_url(), run when the app starts, reads it with the WebBridge, cleans the URL
##   (history.replaceState) and exchanges it with POST /auth/exchange {code}. A fragment with login_error=... is a refused login.
## - Guest: start_guest() (POST /auth/guest): no ranking points.
## On success `account` has the profile and the ApiClient holds the session token (memory only). Failures leave `message`
## (text for a screen) and `error` (the API's code).

const ApiClient := preload("res://scripts/net/api_client.gd")
const Result := preload("res://scripts/net/api_result.gd")
const Account := preload("res://scripts/net/account.gd")
const SteamAuth := preload("res://scripts/net/steam_auth.gd")
const WebBridge := preload("res://scripts/net/web_bridge.gd")

enum State { IDLE, TICKET, REQUESTING, REDIRECTING, DONE, FAILED }

const ERRORS := {
	"banned": "THIS ACCOUNT IS BANNED",
	"invalid_ticket": "STEAM TICKET REFUSED",
	"unauthorized": "STEAM TICKET REFUSED",
	"rate_limited": "TOO MANY TRIES - WAIT A MOMENT",
	"too_many_requests": "TOO MANY TRIES - WAIT A MOMENT",
	"network": "ONLINE UNAVAILABLE",
	"steam_unavailable": "STEAM LOGIN IS UNAVAILABLE",
	"state_mismatch": "LOGIN EXPIRED - TRY AGAIN",
	"invalid_code": "LOGIN EXPIRED - TRY AGAIN",
	"expired": "LOGIN EXPIRED - TRY AGAIN",
}

var api: ApiClient
var account: Account
var steam: SteamAuth = null
var web: WebBridge = null
var state: State = State.IDLE
var error: String = ""
var message: String = ""
## Milliseconds, for Steam's timeout.
var clock: Callable = Callable()


func _init(p_api: ApiClient, p_account: Account, p_steam: SteamAuth = null, p_web: WebBridge = null) -> void:
	api = p_api
	account = p_account
	steam = p_steam
	web = p_web


func on_web() -> bool:
	return web != null and web.available()


## True when "LOGIN WITH STEAM" can do something: a web page to redirect, or a running Steam.
func steam_possible() -> bool:
	return on_web() or (steam != null and steam.available())


func logged_in() -> bool:
	return account.logged_in and api.logged_in()


func busy() -> bool:
	return state in [State.TICKET, State.REQUESTING, State.REDIRECTING]


## The Steam login. On the web it leaves the page.
func start_steam() -> void:
	if busy():
		return
	_reset()
	if on_web():
		state = State.REDIRECTING
		web.navigate(ApiClient.join_url(api.base_url, "auth/openid/start"))
	elif steam != null and steam.begin(_now()):
		state = State.TICKET
	else:
		_fail("steam_unavailable", "")


func start_guest() -> void:
	if busy():
		return
	_reset()
	state = State.REQUESTING
	api.request("POST", "auth/guest", {}, _on_session)


## Web start-up: reads the fragment the login redirect left. Returns true when it held a code or an error (and was cleaned).
func resume_from_url() -> bool:
	if not on_web():
		return false
	var fields := WebBridge.parse_fragment(web.fragment())
	if fields.has("code") or fields.has("login_error"):
		web.clean_url()
		_reset()
		if fields.has("login_error"):
			_fail(str(fields["login_error"]), "")
			return true
		state = State.REQUESTING
		api.request("POST", "auth/exchange", {"code": str(fields["code"])}, _on_session)
		return true
	return false


## Once per frame while a login is going on.
func poll() -> void:
	if state != State.TICKET:
		return
	var answer := steam.poll(_now())
	if answer.is_empty():
		return
	if not bool(answer.get("ok", false)):
		_fail("steam_unavailable", str(answer.get("error", "")))
		return
	state = State.REQUESTING
	api.request("POST", "auth/steam", {"ticket": str(answer["ticket"])}, _on_session)


## Ends the session (the API forgets the token) and the screens go back to the login choice.
func logout() -> void:
	if api.logged_in():
		api.request("POST", "auth/logout", {}, func(_r: Result) -> void: pass)
	api.token = ""
	account.clear()
	state = State.IDLE


## Refreshes the profile (points, division) from GET /me. `done` takes the Result, if given.
func refresh_profile(done: Callable = Callable()) -> void:
	api.request("GET", "me", null, func(r: Result) -> void:
		if r.ok:
			account.set_profile(r.dict())
		elif r.status == 401:
			_expired()
		if done.is_valid():
			done.call(r))


func _on_session(r: Result) -> void:
	if not r.ok:
		_fail(r.error, r.message)
		return
	var body := r.dict()
	var token := str(body.get("token", ""))
	var profile: Variant = body.get("profile")
	if token.is_empty() or not (profile is Dictionary):
		_fail("bad_response", "")
		return
	api.token = token
	account.set_profile(profile)
	state = State.DONE
	error = ""
	message = ""


func _expired() -> void:
	api.token = ""
	account.clear()
	state = State.FAILED
	error = "session_expired"
	message = "SESSION ENDED - LOG IN AGAIN"


func _fail(code: String, detail: String) -> void:
	state = State.FAILED
	error = code
	message = ERRORS.get(code, detail if not detail.is_empty() else "LOGIN FAILED: " + code.to_upper())


func _reset() -> void:
	state = State.IDLE
	error = ""
	message = ""


func _now() -> int:
	return clock.call() if clock.is_valid() else Time.get_ticks_msec()
