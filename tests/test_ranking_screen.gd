extends "res://tests/test_case.gd"
## The leaderboard screen (scripts/app/ranking_screen.gd, scripts/view/ranking_view.gd): reached from the title with
## RANKING, it lists the session's ranking, best first, and any confirm or back command returns to the title.

const S := preload("res://tests/screen_helpers.gd")
const App := preload("res://scripts/app/app.gd")
const Title := preload("res://scripts/app/title.gd")
const RankingView := preload("res://scripts/view/ranking_view.gd")
const ViewConfig := preload("res://scripts/view/view_config.gd")

var app: App


func before_each() -> void:
	app = S.boot(41)


func after_each() -> void:
	S.free_app(app)
	app = null


func test_ranking_is_the_third_title_choice_and_opens_the_leaderboard() -> void:
	S.key_tap(app, KEY_DOWN)
	S.key_tap(app, KEY_DOWN)
	S.frame(app, 0)
	assert_eq(app.current_screen().choice, Title.CHOICE_RANKING)
	S.key_tap(app, KEY_DOWN)
	S.frame(app, 0)
	assert_eq(app.current_screen().choice, Title.CHOICE_RANKING, "nothing below it")
	S.key_tap(app, KEY_ENTER)
	S.frame(app, 0)
	assert_eq(S.screen_name(app), "Ranking")
	S.key_tap(app, KEY_ESCAPE)
	S.frame(app, 0)
	assert_eq(S.screen_name(app), "Title")
	assert_eq(app.current_screen().choice, Title.CHOICE_RANKING, "the title remembers it")


func test_a_click_on_the_ranking_button_opens_it() -> void:
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = Vector2(ViewConfig.RANKING_BUTTON.get_center())
	app.current_screen()._unhandled_input(click)
	assert_eq(S.screen_name(app), "Ranking")


func test_it_lists_the_session_best_first() -> void:
	app.ranking.apply("seat:0", "P1", 10)
	app.ranking.apply("seat:1", "P2", 320)
	app.show_ranking()
	assert_eq(RankingView.row_texts(app.ranking.top(RankingView.ROWS)), ["1 P2 SILVER 320", "2 P1 BRONZE 10"])
	assert_eq(S.screen_name(app), "Ranking")
	var view: RankingView = app.current_screen().get_node("RankingView")
	assert_eq(view.records.size(), 2)


func test_the_panel_fits_the_screen_with_a_full_table_and_with_none() -> void:
	var full: Array[Dictionary] = []
	for i in RankingView.ROWS:
		full.append({"id": "seat:%d" % i, "name": "P%d" % (i + 1), "points": 1800 + i, "matches": 1})
	for records: Array[Dictionary] in [full, [] as Array[Dictionary]]:
		var r := RankingView.panel_rect(records)
		assert_true(Rect2i(0, 0, ViewConfig.VIEW_W, ViewConfig.VIEW_H).encloses(r))
