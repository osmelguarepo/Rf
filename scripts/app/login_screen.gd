extends Node2D
## The login screen (docs/SPEC_ONLINE.md §4, §16.3, §16.5), opened by the title's ONLINE when the app has an API and nobody is logged
## in. Rows, moved with Up and Down:
##   LOGIN WITH STEAM  on the desktop with Steam running: a Steam ticket to the API; on the web: a full-page redirect to Steam's
##                     OpenID (the page comes back with a one-time code, which the app exchanges when it starts: login_flow.gd);
##   PLAY AS GUEST     an unranked guest account (no points);
##   PRIVATE ROOMS     the rooms by code, which need no account;
##   PLAY LOCAL        only after the API could not be reached: the game's offline mode.
## Back returns to the title. Once logged in (a guest too) the screen opens the queue.

const App := preload("res://scripts/app/app.gd")
const Config := preload("res://scripts/sim/config.gd")
const Nav := preload("res://scripts/input/nav.gd")
const Road := preload("res://scripts/view/road.gd")
const QueueView := preload("res://scripts/view/queue_view.gd")
const LoginFlow := preload("res://scripts/net/login_flow.gd")

const ROW_STEAM := "steam"
const ROW_GUEST := "guest"
const ROW_ROOMS := "rooms"
const ROW_LOCAL := "local"
const LABELS := {
	ROW_STEAM: "LOGIN WITH STEAM", ROW_GUEST: "PLAY AS GUEST (NO POINTS)", ROW_ROOMS: "PRIVATE ROOMS", ROW_LOCAL: "PLAY LOCAL",
}

var app: App
var cfg: Config = Config.standard()
var focus: int = 0
var message: String = ""
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
	message = app.online_message
	app.online_message = ""
	if not app.login.busy() and app.login.state == LoginFlow.State.FAILED:
		message = app.login.message
	_show()


func frame(_steps: int, delta: float) -> void:
	time += delta
	for command: Vector2i in app.nav.take():
		if _leaving:
			return
		handle(command.y)
	if _leaving:
		return
	if app.login.logged_in():
		_leaving = true
		app.show_queue()
		return
	if app.login.state == LoginFlow.State.FAILED and not app.login.message.is_empty():
		message = app.login.message
	_show()


func on_focus_lost() -> void:
	pass


## The rows now, as ids.
func rows() -> Array[String]:
	var out: Array[String] = []
	if app.login.steam_possible():
		out.append(ROW_STEAM)
	out.append(ROW_GUEST)
	out.append(ROW_ROOMS)
	if app.login.error == "network":
		out.append(ROW_LOCAL)
	return out


func handle(command: int) -> void:
	if app.login.busy():
		if command == Nav.BACK:
			_leaving = true
			app.show_title()
		return
	var ids := rows()
	match command:
		Nav.UP:
			focus = maxi(focus - 1, 0)
		Nav.DOWN:
			focus = mini(focus + 1, ids.size() - 1)
		Nav.BACK:
			_leaving = true
			app.show_title()
		Nav.ACCEPT, Nav.START:
			_choose(ids[clampi(focus, 0, ids.size() - 1)])


func _choose(id: String) -> void:
	message = ""
	match id:
		ROW_STEAM:
			app.login.start_steam()
		ROW_GUEST:
			app.login.start_guest()
		ROW_ROOMS:
			_leaving = true
			app.show_online()
		ROW_LOCAL:
			_leaving = true
			app.show_join()


func _show() -> void:
	var data := {"title": "ONLINE", "subtitle": "LOG IN TO PLAY RANKED RACES", "message": message, "hints": []}
	if app.login.busy():
		data["headline"] = "OPENING STEAM..." if app.login.state == LoginFlow.State.REDIRECTING else "LOGGING IN..."
		data["hints"] = ["BACK / ESC  TITLE"]
	else:
		var labels: Array[String] = []
		for id in rows():
			labels.append(LABELS[id])
		data["rows"] = labels
		data["focus"] = focus
		data["hints"] = ["UP / DOWN  MOVE    ACCEPT  CHOOSE", "BACK / ESC  TITLE"]
		if not app.login.steam_possible():
			data["lines"] = ["STEAM IS NOT AVAILABLE HERE: PLAY AS GUEST"]
	view.show_state(data)
