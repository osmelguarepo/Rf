extends Node2D
## The online hub and queue screen (docs/SPEC_ONLINE.md §7, §16.4, M4): where the title's ONLINE leads once the player is logged in.
##
## MENU, rows moved with Up and Down:
##   FIND RACE      measures the latency to each region, joins the queue (matchmaking.gd) and shows the search;
##   PRIVATE ROOMS  the rooms by code (online.gd): no points;
##   RANKING        the online leaderboard;
##   LOG OUT        forgets the session.
## SEARCHING shows "SEARCHING FOR RIVALS" with the time waited, the band of divisions the match may span and the players found; when
## a match is found, a ready check with a countdown (Accept to join, Back to refuse); then "WAITING FOR THE OTHERS". Back cancels at
## any point (DELETE /queue). When the API starts the match the screen asks for the connection (GET /match/{id}/join), opens the
## WebSocket with the ticket and, once the server welcomes it, the race opens (App.start_online_race(), versus.gd) exactly as for a
## private room. Failures (a penalty for leaving matches, a server that does not answer, an old game version) are messages here.
##
## Everything it knows about the queue comes from the Matchmaking object; the screen only draws and sends commands.

const App := preload("res://scripts/app/app.gd")
const Config := preload("res://scripts/sim/config.gd")
const Nav := preload("res://scripts/input/nav.gd")
const Road := preload("res://scripts/view/road.gd")
const QueueView := preload("res://scripts/view/queue_view.gd")
const Matchmaking := preload("res://scripts/net/matchmaking.gd")
const OnlineSession := preload("res://scripts/net/online_session.gd")
const Online := preload("res://scripts/app/online.gd")

enum Step { MENU, SEARCHING, CONNECTING, FAILED }

const ROW_FIND := 0
const ROW_ROOMS := 1
const ROW_RANKING := 2
const ROW_LOGOUT := 3
const ROWS: Array[String] = ["FIND RACE", "PRIVATE ROOMS", "RANKING", "LOG OUT"]
## Why a server turned the client away (EVENT_REJECT's text), on top of the private rooms' list.
const REASONS := {
	"version": "UPDATE THE GAME", "sim_hash": "UPDATE THE GAME", "expired": "THE MATCH TICKET EXPIRED - TRY AGAIN",
	"bad_signature": "THE SERVER REFUSED THE TICKET", "wrong_server": "THE SERVER REFUSED THE TICKET",
	"format": "THE SERVER REFUSED THE TICKET", "draining": "THE SERVER IS RESTARTING - TRY AGAIN",
	"seat": "THE SEAT IS NOT YOURS", "mismatch": "THE SERVER DOES NOT KNOW THIS MATCH",
}

var app: App
var cfg: Config = Config.standard()
var step: Step = Step.MENU
var focus: int = ROW_FIND
var message: String = ""
var mm: Matchmaking
var session: OnlineSession = null
## Seconds since the screen opened.
var time: float = 0.0
var road: Road
var view: QueueView
var _leaving := false


func setup(p_app: App) -> void:
	app = p_app
	road = $Road
	view = $QueueView
	road.beside_panels = false
	road.setup(app.atlas, cfg)
	view.setup(app.atlas)
	mm = Matchmaking.new(app.api)
	mm.regions = app.regions
	mm.clock = app.online_now
	mm.unix_clock = app.unix_now
	message = app.online_message
	app.online_message = ""
	if app.login.logged_in():
		app.login.refresh_profile()
	_show()


func frame(_steps: int, delta: float) -> void:
	time += delta
	for command: Vector2i in app.nav.take():
		if _leaving:
			return
		handle(command.y)
	if _leaving:
		return
	mm.update(app.online_now())
	if session != null:
		session.update(app.online_now())
	_follow()
	_show()


func on_focus_lost() -> void:
	pass


## One menu command.
func handle(command: int) -> void:
	match step:
		Step.MENU:
			_menu(command)
		Step.SEARCHING:
			if command == Nav.BACK or command == Nav.SELECT:
				_cancel_search("LEFT THE QUEUE")
			elif (command == Nav.ACCEPT or command == Nav.START) and mm.state == Matchmaking.State.FOUND:
				mm.accept()
		Step.CONNECTING:
			if command == Nav.BACK or command == Nav.SELECT:
				_drop_session("")
		Step.FAILED:
			if command == Nav.ACCEPT or command == Nav.BACK or command == Nav.START:
				if not app.login.logged_in():
					_leaving = true
					app.show_login(message)
				else:
					step = Step.MENU
					message = ""


func _menu(command: int) -> void:
	match command:
		Nav.UP:
			focus = maxi(focus - 1, 0)
		Nav.DOWN:
			focus = mini(focus + 1, ROWS.size() - 1)
		Nav.BACK:
			_leaving = true
			app.show_title()
		Nav.ACCEPT, Nav.START:
			match focus:
				ROW_FIND:
					message = ""
					mm.find_race()
					step = Step.SEARCHING
				ROW_ROOMS:
					_leaving = true
					app.show_online()
				ROW_RANKING:
					_leaving = true
					app.show_ranking()
				ROW_LOGOUT:
					app.login.logout()
					_leaving = true
					app.show_title()


func _cancel_search(text: String) -> void:
	mm.cancel()
	step = Step.MENU
	message = text


## What the queue and the session say moves the screen along.
func _follow() -> void:
	if step == Step.SEARCHING:
		match mm.state:
			Matchmaking.State.JOINED:
				_connect()
			Matchmaking.State.FAILED:
				if mm.error == "session_expired":
					app.login.logout()
				step = Step.FAILED
				message = mm.message
			Matchmaking.State.IDLE:
				step = Step.MENU
				message = mm.message
	elif step == Step.CONNECTING and session != null:
		match session.state:
			OnlineSession.State.WAITING, OnlineSession.State.PLAYING, OnlineSession.State.ENDED:
				_leaving = true
				app.start_online_race(session, true, mm.match_id)
			OnlineSession.State.REJECTED:
				_drop_session(reason_text(session.reject_reason, app.web_mode))
			OnlineSession.State.FAILED:
				_drop_session("CONNECTION FAILED")


## The text for a server's refusal.
static func reason_text(reason: String, web: bool = false) -> String:
	if reason == "version" or reason == "sim_hash":
		return "RELOAD THE PAGE TO UPDATE THE GAME" if web else "UPDATE THE GAME"
	return str(REASONS.get(reason, Online.REASONS.get(reason, "REFUSED: " + reason.to_upper())))


func _connect() -> void:
	session = OnlineSession.new()
	var address: String = mm.join["ws_url"]
	session.reconnect_factory = app.make_online_transport
	session.reconnect_address = address
	if session.connect_to(app.make_online_transport(), address, mm.join["ticket"]) != OK:
		_drop_session("COULD NOT CONNECT")
		return
	step = Step.CONNECTING


func _drop_session(reason: String) -> void:
	if session != null:
		session.close()
		session = null
	mm.cancel()
	step = Step.FAILED if not reason.is_empty() else Step.MENU
	message = reason


## "M:SS".
static func clock_text(seconds: int) -> String:
	return "%d:%02d" % [floori(seconds / 60.0), seconds % 60]


func _show() -> void:
	var data := {"title": "ONLINE", "subtitle": app.account.summary(), "message": message, "hints": []}
	match step:
		Step.MENU:
			data["rows"] = ROWS
			data["focus"] = focus
			data["hints"] = ["UP / DOWN  MOVE    ACCEPT  CHOOSE", "BACK / ESC  TITLE"]
		Step.SEARCHING:
			_show_search(data)
		Step.CONNECTING:
			data["headline"] = "CONNECTING TO THE RACE..."
			data["hints"] = ["BACK / ESC  CANCEL"]
		Step.FAILED:
			data["hints"] = ["ACCEPT / BACK  CONTINUE"]
	view.show_state(data)


func _show_search(data: Dictionary) -> void:
	match mm.state:
		Matchmaking.State.MEASURING, Matchmaking.State.JOINING:
			data["headline"] = "CONNECTING..."
		Matchmaking.State.FOUND:
			data["headline"] = "MATCH FOUND"
			data["lines"] = ["PLAYERS  %d" % mm.players_found, "ACCEPT IN  %d" % mm.countdown_s()]
			data["message"] = "PRESS ACCEPT TO PLAY"
			data["good"] = true
		Matchmaking.State.READY:
			data["headline"] = "WAITING FOR THE OTHERS"
			data["lines"] = ["READY IN  %d" % mm.countdown_s()]
		Matchmaking.State.STARTING:
			data["headline"] = "STARTING..."
		_:
			data["headline"] = "SEARCHING FOR RIVALS"
			data["lines"] = [
				"TIME  %s" % clock_text(mm.wait_s), "DIVISIONS  +/- %d" % mm.band_divisions, "PLAYERS FOUND  %d" % mm.players_found,
			]
	if mm.state == Matchmaking.State.FOUND:
		data["hints"] = ["ACCEPT  PLAY    BACK / ESC  REFUSE"]
	else:
		data["hints"] = ["BACK / ESC  CANCEL"]


func _exit_tree() -> void:
	# A search that is not going to the race ends with the screen; a session likewise.
	if mm != null and mm.active():
		mm.cancel()
	if session != null and not app.online_session_is(session):
		session.close()
