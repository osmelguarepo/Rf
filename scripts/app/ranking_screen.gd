extends Node2D
## The leaderboard screen (docs/SPEC_RANKING.md §9), opened from the title: the session's players, most points first,
## each with their division. When the player is logged in (app.online_ranking), it shows the best players of the online leaderboard
## instead (GET /leaderboard, via OnlineRankingStore) once they arrive. Any confirm or back command
## (Enter, Space, Esc, a pad's A, B, Start or Back) returns to the title.

const App := preload("res://scripts/app/app.gd")
const Config := preload("res://scripts/sim/config.gd")
const Nav := preload("res://scripts/input/nav.gd")
const Road := preload("res://scripts/view/road.gd")
const RankingView := preload("res://scripts/view/ranking_view.gd")
const RankingStore := preload("res://scripts/app/ranking_store.gd")
const OnlineRankingStore := preload("res://scripts/app/online_ranking_store.gd")

var app: App
var cfg: Config = Config.standard()
var road: Road
var view: RankingView
var store: RankingStore = null
var _leaving := false
var _shown_loaded := false


## Builds the screen. The app calls it before adding the screen to the tree.
func setup(p_app: App) -> void:
	app = p_app
	road = $Road
	view = $RankingView
	road.beside_panels = false
	road.setup(app.atlas, cfg)
	store = app.online_ranking if app.online_ranking != null else app.ranking
	view.setup(app.atlas, store.top(RankingView.ROWS))
	if app.online_ranking != null:
		view.set_status("LOADING...")
		app.online_ranking.refresh(RankingView.ROWS)


func frame(_steps: int, _delta: float) -> void:
	if app.online_ranking != null and not _shown_loaded and (app.online_ranking.loaded or app.online_ranking.failed):
		_shown_loaded = true
		view.set_status("ONLINE RANKING UNAVAILABLE" if app.online_ranking.failed else "")
		view.setup(app.atlas, store.top(RankingView.ROWS))
	for command: Vector2i in app.nav.take():
		if _leaving:
			return
		if command.y in [Nav.ACCEPT, Nav.BACK, Nav.START, Nav.SELECT]:
			_leaving = true
			app.show_title()


func on_focus_lost() -> void:
	pass
