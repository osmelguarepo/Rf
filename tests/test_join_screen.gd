extends "res://tests/test_case.gd"
## The join screen (B2, scripts/app/join.gd) through a real App and synthetic joypad events (tests/screen_helpers.gd):
## A from several pads seats them in join order with fixed colours, B leaves, Left and Right change the bots within
## the rules, Start begins only when a match is valid (and only from a seated pad), Back and Esc go to the title, and
## the view shows what the seats are.

const S := preload("res://tests/screen_helpers.gd")
const App := preload("res://scripts/app/app.gd")
const Seats := preload("res://scripts/input/seats.gd")
const JoinView := preload("res://scripts/view/join_view.gd")
const PlayerColours := preload("res://scripts/view/player_colours.gd")
const ViewConfig := preload("res://scripts/view/view_config.gd")
const Draw := preload("res://scripts/view/draw.gd")

const PADS: Array[int] = [40, 41, 42, 43, 44, 45, 46]

var app: App
var seats: Seats


func before_each() -> void:
	app = S.boot(7)
	app.show_join()
	seats = app.seats


func after_each() -> void:
	S.free_app(app)
	app = null
	seats = null
	S.release(PADS)


func test_the_join_screen_opens_empty_on_the_seats_input() -> void:
	assert_eq(S.screen_name(app), "Join")
	assert_eq(app.input, app.seats)
	assert_eq(seats.people(), 0)
	assert_false(seats.locked)
	var view: JoinView = app.current_screen().get_node("JoinView")
	S.frame(app, 0)
	assert_eq(view.kinds, [Seats.FREE, Seats.FREE, Seats.FREE, Seats.FREE, Seats.FREE, Seats.FREE] as Array[int])


## Pads that press A take the seats in the order they press it, each with its seat's colour for good.
func test_a_from_several_pads_seats_them_in_join_order() -> void:
	S.tap(app, 42, JOY_BUTTON_A)
	S.tap(app, 40, JOY_BUTTON_A)
	S.tap(app, 45, JOY_BUTTON_A)
	S.frame(app, 0)
	assert_eq([seats.seat_of(42), seats.seat_of(40), seats.seat_of(45)], [0, 1, 2])
	S.tap(app, 40, JOY_BUTTON_A)
	S.frame(app, 0)
	assert_eq(seats.people(), 3, "A again on a seated pad changes nothing")
	S.tap(app, 40, JOY_BUTTON_B)
	S.frame(app, 0)
	assert_eq(seats.seat_of(40), -1, "B leaves")
	assert_eq([seats.seat_of(42), seats.seat_of(45)], [0, 2], "the others keep their seats and colours")
	S.tap(app, 43, JOY_BUTTON_A)
	S.frame(app, 0)
	assert_eq(seats.seat_of(43), 1, "the next pad takes the free seat, with its colour")
	var view: JoinView = app.current_screen().get_node("JoinView")
	assert_eq(view.kinds.slice(0, 4), [Seats.PERSON, Seats.PERSON, Seats.PERSON, Seats.FREE] as Array[int])


## B on a pad that holds no seat, and the keyboard's keys other than Esc, do nothing here.
func test_b_leaves_only_a_seated_pad() -> void:
	S.tap(app, 40, JOY_BUTTON_A)
	S.tap(app, 41, JOY_BUTTON_B)
	S.key_tap(app, KEY_ENTER)
	S.key_tap(app, KEY_RIGHT)
	S.frame(app, 0)
	assert_eq(seats.people(), 1)
	assert_eq(seats.bots, 1)
	assert_eq(S.screen_name(app), "Join")


## Left and Right on any seated pad change the bots: one at least with one person, six cars at most; bots take the
## lowest free seats and the view shows them as bots.
func test_left_and_right_change_the_bots_within_the_rules() -> void:
	S.tap(app, 40, JOY_BUTTON_A)
	S.frame(app, 0)
	assert_eq(seats.bots, 1, "one person gets a bot")
	S.tap(app, 40, JOY_BUTTON_DPAD_LEFT)
	S.frame(app, 0)
	assert_eq(seats.bots, 1, "never below one with one person")
	for i in 8:
		S.tap(app, 40, JOY_BUTTON_DPAD_RIGHT)
	S.frame(app, 0)
	assert_eq(seats.bots, 5, "never more than six cars")
	S.tap(app, 41, JOY_BUTTON_DPAD_LEFT)
	S.frame(app, 0)
	assert_eq(seats.bots, 5, "a pad that holds no seat does not count")
	S.tap(app, 41, JOY_BUTTON_A)
	S.frame(app, 0)
	assert_eq(seats.bots, 4, "a person takes a bot's place")
	S.deliver(app, _axis(41, JOY_AXIS_LEFT_X, -0.9))
	S.deliver(app, _axis(41, JOY_AXIS_LEFT_X, 0.0))
	S.deliver(app, _axis(41, JOY_AXIS_LEFT_X, -0.9))
	S.frame(app, 0)
	assert_eq(seats.bots, 2, "the stick, twice")
	var view: JoinView = app.current_screen().get_node("JoinView")
	assert_eq(view.kinds, [Seats.PERSON, Seats.PERSON, Seats.BOT, Seats.BOT, Seats.FREE, Seats.FREE] as Array[int])
	assert_eq(view.bots, 2)
	S.tap(app, 40, JOY_BUTTON_B)
	S.frame(app, 0)
	assert_eq(view.kinds, [Seats.BOT, Seats.PERSON, Seats.BOT, Seats.FREE, Seats.FREE, Seats.FREE] as Array[int],
		"a bot takes the free seat, the person keeps seat 1")


## Start begins the race only from a seated pad and only when World.versus_valid() holds for the seats.
func test_start_begins_only_when_valid() -> void:
	S.tap(app, 40, JOY_BUTTON_START)
	S.frame(app, 0)
	assert_eq(S.screen_name(app), "Join", "nobody has joined")
	S.tap(app, 40, JOY_BUTTON_A)
	S.frame(app, 0)
	seats.bots = 0
	S.tap(app, 40, JOY_BUTTON_START)
	S.frame(app, 0)
	assert_eq(S.screen_name(app), "Join", "one car is no match")
	assert_false(seats.locked)
	seats.set_bots(1)
	S.tap(app, 41, JOY_BUTTON_START)
	S.frame(app, 0)
	assert_eq(S.screen_name(app), "Join", "a pad that holds no seat cannot start")
	S.tap(app, 40, JOY_BUTTON_START)
	S.frame(app, 0)
	assert_eq(S.screen_name(app), "Versus")
	assert_true(seats.locked)
	assert_eq(seats.lineup, [0, 1] as Array[int])
	assert_eq(seats.humans_mask(), 0b01)


func test_back_on_a_seated_pad_or_esc_goes_to_the_title() -> void:
	S.tap(app, 41, JOY_BUTTON_BACK)
	S.frame(app, 0)
	assert_eq(S.screen_name(app), "Join", "a pad that holds no seat")
	S.tap(app, 40, JOY_BUTTON_A)
	S.tap(app, 40, JOY_BUTTON_BACK)
	S.frame(app, 0)
	assert_eq(S.screen_name(app), "Title")
	assert_eq(seats.people(), 0, "the title lets every pad go")
	assert_eq(app.input, app.solo)
	app.show_join()
	S.tap(app, 40, JOY_BUTTON_A)
	S.key_tap(app, KEY_ESCAPE)
	S.frame(app, 0)
	assert_eq(S.screen_name(app), "Title")


## A pad that goes away on the join screen leaves its seat.
func test_a_pad_that_goes_away_leaves_its_seat() -> void:
	S.tap(app, 40, JOY_BUTTON_A)
	S.tap(app, 41, JOY_BUTTON_A)
	S.frame(app, 0)
	Input.joy_connection_changed.emit(40, false)
	S.frame(app, 0)
	assert_eq(seats.seat_of(40), -1)
	assert_eq(seats.seat_of(41), 1)
	assert_eq(seats.kind_of(0), Seats.BOT, "the lone person's bot takes the lowest free seat")


## Presses made on the join screen never reach the race.
func test_presses_on_the_join_screen_are_dropped() -> void:
	S.tap(app, 40, JOY_BUTTON_A)
	S.frame(app, 0)
	S.tap(app, 40, JOY_BUTTON_A)
	S.frame(app, 0)
	assert_eq(seats.take_presses(), 0)


## Every card fits the screen, side by side, and its texts fit the card.
func test_the_cards_fit() -> void:
	var font := app.atlas.font
	var screen := Rect2i(0, 0, ViewConfig.VIEW_W, ViewConfig.VIEW_H)
	for seat in Seats.SEATS:
		var card := JoinView.card_rect(seat)
		assert_true(screen.encloses(card), "card %d on screen" % seat)
		if seat > 0:
			assert_false(card.intersects(JoinView.card_rect(seat - 1)))
		for text: String in [PlayerColours.label(seat, true), "BOT"]:
			assert_lt(Draw.text_width(font, text, ViewConfig.TEXT_MEDIUM), card.size.x - 8)
		for kind: int in [Seats.FREE, Seats.PERSON, Seats.BOT]:
			assert_lt(Draw.text_width(font, JoinView.state_text(kind), ViewConfig.TEXT_SMALL), card.size.x - 8)
	for line: String in JoinView.HINTS + [JoinView.SUBTITLE, JoinView.status_text(true, 6, 2)]:
		assert_lt(Draw.text_width(font, line, ViewConfig.TEXT_SMALL), ViewConfig.VIEW_W - 16, line)


# --- helpers ---------------------------------------------------------------------------------------------------------


static func _axis(device: int, axis: JoyAxis, value: float) -> InputEventJoypadMotion:
	var event := InputEventJoypadMotion.new()
	event.device = device
	event.axis = axis
	event.axis_value = value
	return event
