extends Node2D
## The ONLINE screen (docs/SPEC_ONLINE.md §16.4, M2): private rooms, no matchmaking and no ranking points yet. A menu of four
## rows, moved with Up and Down:
##   NAME         Accept edits it (the same arcade way as the join screen: Up and Down change the last letter, Right adds a
##                letter, Left takes one away; Accept or Back stops) - it is seat 0's name of the app's Names;
##   CREATE ROOM  makes a room on the server and waits in its lobby;
##   JOIN ROOM    joins the room whose code is in CODE;
##   CODE         Accept edits the six characters of a room code the same way.
## Back returns to the title. Connecting, the lobby (the room's code, who sits where; the owner starts the match with
## Accept or Start) and failures are steps of this screen. When the server welcomes the match, the race opens
## (App.start_online_race(), versus.gd with the session): the player is in the match.
##
## The connection is an OnlineSession over the transport the app makes (a WebSocket to App.online_server unless a test gives
## another), and the screen only reads its state.

const App := preload("res://scripts/app/app.gd")
const Config := preload("res://scripts/sim/config.gd")
const Nav := preload("res://scripts/input/nav.gd")
const Road := preload("res://scripts/view/road.gd")
const OnlineView := preload("res://scripts/view/online_view.gd")
const OnlineSession := preload("res://scripts/net/online_session.gd")
const RoomCode := preload("res://scripts/net/room_code.gd")
const Protocol := preload("res://scripts/net/protocol.gd")

enum Step { MENU, CONNECTING, LOBBY, FAILED }

const ROW_NAME := 0
const ROW_CREATE := 1
const ROW_JOIN := 2
const ROW_CODE := 3
const ROWS: Array[String] = ["NAME", "CREATE ROOM", "JOIN ROOM", "CODE"]
## The seat of Names this screen edits.
const NAME_SEAT := 0
const REASONS := {
	"version": "UPDATE THE GAME", "sim_hash": "UPDATE THE GAME", "no_room": "NO ROOM WITH THAT CODE",
	"full": "THE ROOM IS FULL", "seat": "THE SEAT IS NOT YOURS", "private_off": "PRIVATE ROOMS ARE OFF",
	"bad_hello": "THE SERVER DID NOT UNDERSTAND", "mismatch": "THE SERVER DOES NOT KNOW THIS MATCH",
}

var app: App
var cfg: Config = Config.standard()
var step: Step = Step.MENU
var focus: int = ROW_CREATE
var editing: bool = false
var code_text: String = ""
var message: String = ""
var session: OnlineSession = null
## Seconds since the screen opened.
var time: float = 0.0
var road: Road
var view: OnlineView
var _leaving := false


## Builds the screen. The app calls it before adding the screen to the tree. `app.online_message` (why the last connection
## ended) is shown once.
func setup(p_app: App) -> void:
	app = p_app
	road = $Road
	view = $OnlineView
	road.beside_panels = false
	road.setup(app.atlas, cfg)
	view.setup(app.atlas)
	message = app.online_message
	app.online_message = ""
	code_text = app.online_code
	_show()


func frame(_steps: int, delta: float) -> void:
	time += delta
	for command: Vector2i in app.nav.take():
		if _leaving:
			return
		handle(command.y)
	if _leaving:
		return
	if session != null:
		session.update(app.online_now())
		_follow_session()
	_show()


func on_focus_lost() -> void:
	pass


## One menu command.
func handle(command: int) -> void:
	match step:
		Step.MENU:
			_menu(command)
		Step.CONNECTING:
			if command == Nav.BACK:
				_drop_session("")
		Step.LOBBY:
			if command == Nav.BACK or command == Nav.SELECT:
				_drop_session("")
			elif (command == Nav.ACCEPT or command == Nav.START) and session != null and session.lobby.get("owner", false):
				session.send_start()
		Step.FAILED:
			if command == Nav.ACCEPT or command == Nav.BACK or command == Nav.START:
				step = Step.MENU


func _menu(command: int) -> void:
	if editing:
		_edit(command)
		return
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
				ROW_NAME, ROW_CODE:
					editing = true
					message = ""
				ROW_CREATE:
					_connect(RoomCode.new_ticket(app.names.name_of(NAME_SEAT)))
				ROW_JOIN:
					if code_text.length() == RoomCode.CODE_LENGTH:
						_connect(RoomCode.join_ticket(code_text, app.names.name_of(NAME_SEAT)))
					else:
						message = "TYPE THE %d-LETTER CODE FIRST" % RoomCode.CODE_LENGTH


## Editing the name or the code: letters the arcade way.
func _edit(command: int) -> void:
	if command == Nav.ACCEPT or command == Nav.BACK or command == Nav.START:
		editing = false
		return
	if focus == ROW_NAME:
		match command:
			Nav.UP:
				app.names.cycle(NAME_SEAT, 1)
			Nav.DOWN:
				app.names.cycle(NAME_SEAT, -1)
			Nav.RIGHT:
				app.names.extend(NAME_SEAT)
			Nav.LEFT:
				app.names.shorten(NAME_SEAT)
		return
	match command:
		Nav.UP, Nav.DOWN:
			if code_text.is_empty():
				code_text = RoomCode.ALPHABET[0]
			else:
				var at := RoomCode.ALPHABET.find(code_text[code_text.length() - 1])
				var next := posmod(at + (1 if command == Nav.UP else -1), RoomCode.ALPHABET.length())
				code_text = code_text.substr(0, code_text.length() - 1) + RoomCode.ALPHABET[next]
		Nav.RIGHT:
			if code_text.length() < RoomCode.CODE_LENGTH:
				code_text += RoomCode.ALPHABET[0]
		Nav.LEFT:
			code_text = code_text.substr(0, maxi(code_text.length() - 1, 0))
	app.online_code = code_text


func _connect(ticket: String) -> void:
	message = ""
	session = OnlineSession.new()
	if session.connect_to(app.make_online_transport(), app.online_server, ticket) != OK:
		_drop_session("COULD NOT CONNECT")
		return
	step = Step.CONNECTING


func _drop_session(reason: String) -> void:
	if session != null:
		session.close()
		session = null
	step = Step.FAILED if not reason.is_empty() else Step.MENU
	message = reason


## What the session says moves the screen along.
func _follow_session() -> void:
	match session.state:
		OnlineSession.State.LOBBY:
			step = Step.LOBBY
		OnlineSession.State.WAITING, OnlineSession.State.PLAYING, OnlineSession.State.ENDED:
			_leaving = true
			app.start_online_race(session)
		OnlineSession.State.REJECTED:
			_drop_session(REASONS.get(session.reject_reason, "REFUSED: " + session.reject_reason.to_upper()))
		OnlineSession.State.FAILED:
			_drop_session("CONNECTION FAILED" if session.failure != "closed" else "COULD NOT CONNECT")


func _show() -> void:
	var data := {"time": time, "message": message, "step": "menu", "hints": []}
	match step:
		Step.MENU:
			data["rows"] = ROWS
			data["focus"] = focus
			data["editing"] = editing
			data["name"] = app.names.name_of(NAME_SEAT)
			data["code"] = code_text
			data["hints"] = [
				"UP / DOWN  MOVE    ACCEPT  CHOOSE / EDIT", "EDIT: UP / DOWN  LETTER   RIGHT  ADD   LEFT  DELETE",
				"BACK / ESC  TITLE",
			]
		Step.CONNECTING:
			data["step"] = "connecting"
			data["message"] = "CONNECTING..."
			data["hints"] = ["BACK / ESC  CANCEL"]
		Step.LOBBY:
			data["step"] = "lobby"
			data["room_code"] = session.lobby.get("code", "")
			data["seat_names"] = session.lobby.get("names", PackedStringArray())
			data["seat"] = session.lobby.get("seat", -1)
			data["owner"] = session.lobby.get("owner", false)
			data["hints"] = ["TELL YOUR FRIENDS THE CODE   BOTS FILL THE EMPTY SEATS", "BACK / ESC  LEAVE"]
		Step.FAILED:
			data["step"] = "failed"
			data["hints"] = ["ACCEPT / BACK  CONTINUE"]
	view.show_state(data)


func _exit_tree() -> void:
	# A session that is not going to the race ends with the screen.
	if session != null and not app.online_session_is(session):
		session.close()
