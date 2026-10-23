extends "res://tests/test_case.gd"
## The seats' names (scripts/app/names.gd; docs/SPEC_RANKING.md §8) and their editing on the join screen with the menu
## commands.

const S := preload("res://tests/screen_helpers.gd")
const App := preload("res://scripts/app/app.gd")
const Names := preload("res://scripts/app/names.gd")
const Seats := preload("res://scripts/input/seats.gd")
const JoinView := preload("res://scripts/view/join_view.gd")
const VersusHud := preload("res://scripts/view/versus_hud.gd")

var app: App


func before_each() -> void:
	app = S.boot(41)


func after_each() -> void:
	S.free_app(app)
	app = null
	S.release([30])


func test_a_seat_is_called_p1_to_p6_until_edited() -> void:
	var names := Names.new()
	assert_eq([names.name_of(0), names.name_of(5)], ["P1", "P6"])
	assert_false(names.is_custom(0))


func test_editing_starts_from_the_default_and_keeps_3_to_8_characters() -> void:
	var names := Names.new()
	names.cycle(2, 1)
	assert_eq(names.name_of(2), "P3B", "the default plus a letter, then its last letter moves")
	names.cycle(2, -1)
	names.cycle(2, -1)
	assert_eq(names.name_of(2), "P39", "round the end of the letters")
	for i in 10:
		names.extend(2)
	assert_eq(names.name_of(2).length(), Names.MAX_LENGTH)
	for i in 5:
		names.shorten(2)
	assert_eq(names.name_of(2), "P39", "three letters")
	names.shorten(2)
	assert_eq(names.name_of(2), "P3", "shorter than that is the default again")
	names.shorten(2)
	assert_eq(names.name_of(2), "P3")
	names.cycle(9, 1)
	assert_eq(names.name_of(9), "P10", "a seat that does not exist is untouched")


func test_the_join_screen_edits_the_name_of_the_seat_a_pad_or_the_keyboard_holds() -> void:
	app.show_join()
	var join := app.current_screen()
	app.seats.join_keyboard()
	join.handle(-1, 1)
	assert_eq(app.names.name_of(0), "P1B", "keyboard up")
	join.handle(-1, 4)
	assert_eq(app.names.name_of(0), "P1BA", "keyboard right")
	join.handle(-1, 3)
	join.handle(-1, 3)
	assert_eq(app.names.name_of(0), "P1", "keyboard left, twice")
	join.handle(30, 1)
	assert_false(app.names.is_custom(1), "a pad with no seat edits nothing")
	assert_eq(app.seats.seat_of(Seats.KEYBOARD_DEVICE), 0)


func test_a_card_shows_the_name_and_a_long_one_still_fits() -> void:
	app.show_join()
	app.seats.join_keyboard()
	for i in 8:
		app.names.extend(0)
	var view: JoinView = app.current_screen().get_node("JoinView")
	app.current_screen().frame(0, 0.0)
	assert_eq(view.names.name_of(0).length(), Names.MAX_LENGTH)
	var inner := JoinView.card_rect(0).grow(-JoinView.CARD_BORDER)
	assert_lt(app.atlas.font.get_string_size(view.names.name_of(0), HORIZONTAL_ALIGNMENT_LEFT, -1, 8).x, inner.size.x)
