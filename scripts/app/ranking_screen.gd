extends Node2D
## The leaderboard screen (docs/SPEC_RANKING.md §9), opened from the title: the session's players, most points first,
## each with their division. ONLINE will show the best players of the database here. Any confirm or back command
## (Enter, Space, Esc, a pad's A, B, Start or Back) returns to the title.

const App := preload("res://scripts/app/app.gd")
const Config := preload("res://scripts/sim/config.gd")
const Nav := preload("res://scripts/input/nav.gd")
const Road := preload("res://scripts/view/road.gd")
const RankingView := preload("res://scripts/view/ranking_view.gd")

var app: App
var cfg: Config = Config.standard()
var road: Road
var view: RankingView
var _leaving := false


## Builds the screen. The app calls it before adding the screen to the tree.
func setup(p_app: App) -> void:
	app = p_app
	road = $Road
	view = $RankingView
	road.beside_panels = false
	road.setup(app.atlas, cfg)
	view.setup(app.atlas, app.ranking.top(RankingView.ROWS))


func frame(_steps: int, _delta: float) -> void:
	for command: Vector2i in app.nav.take():
		if _leaving:
			return
		if command.y in [Nav.ACCEPT, Nav.BACK, Nav.START, Nav.SELECT]:
			_leaving = true
			app.show_title()


func on_focus_lost() -> void:
	pass
