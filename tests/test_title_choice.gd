extends "res://tests/test_case.gd"
## The title's modes and the fullscreen keys: Up and Down choose between LOCAL and ONLINE with keys, the D-pad or
## the stick; a confirm press picks LOCAL (the join screen with the seats) or ONLINE (the private rooms: scripts/app/online.gd); the single-player game stays reachable from the code (App.start_game()), not from the title; a click picks a button; F11 and Alt+Enter
## switch fullscreen on every screen and never reach the screens. Each test boots a real App (tests/screen_helpers.gd).

const S := preload("res://tests/screen_helpers.gd")
const App := preload("res://scripts/app/app.gd")
const LocalInput := preload("res://scripts/input/local_input.gd")
const Seats := preload("res://scripts/input/seats.gd")
const Title := preload("res://scripts/app/title.gd")
const TitleView := preload("res://scripts/view/title_view.gd")
const ViewConfig := preload("res://scripts/view/view_config.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")
const World := preload("res://scripts/sim/world.gd")
const Config := preload("res://scripts/sim/config.gd")

const PADS: Array[int] = [30, 31]

var app: App
## The stand-in window of the fullscreen tests.
var window: Window


func before_each() -> void:
	app = S.boot(41)


func after_each() -> void:
	S.free_app(app)
	app = null
	if window != null:
		window.free()
		window = null
	S.release(PADS)


func test_the_title_opens_on_local() -> void:
	var title := app.current_screen()
	assert_eq(S.screen_name(app), "Title")
	assert_eq(title.choice, Title.CHOICE_LOCAL)
	assert_eq(title.get_node("TitleView").choice, Title.CHOICE_LOCAL)
	assert_eq(ViewConfig.TITLE_CHOICES, ["LOCAL", "ONLINE", "RANKING"])


## The single-player game (stages) is no longer on the title, but the app can still start it: the keyboard-and-every-pad
## input, as before.
func test_the_app_can_still_start_the_single_player_game() -> void:
	app.start_game()
	S.frame(app, 0)
	assert_eq(S.screen_name(app), "Game")
	var world: World = app.current_screen().world
	assert_eq(world.mode, World.MODE_STAGES)
	assert_eq(world.players.size(), 1)
	assert_eq(world.game_seed, 41)
	assert_eq(app.input, app.solo)
	assert_false(app.input is Seats, "single player keeps the keyboard-and-every-pad input")


## Keys, the D-pad and the stick move between the choices; the view follows; confirm then opens the join screen.
func test_up_and_down_choose_and_confirm_picks() -> void:
	var title := app.current_screen()
	S.key_tap(app, KEY_DOWN)
	S.frame(app, 0)
	assert_eq(title.choice, Title.CHOICE_ONLINE, "Down")
	assert_eq(title.get_node("TitleView").choice, Title.CHOICE_ONLINE)
	S.tap(app, 30, JOY_BUTTON_DPAD_UP)
	S.frame(app, 0)
	assert_eq(title.choice, Title.CHOICE_LOCAL, "D-pad up")
	S.deliver(app, _axis(31, JOY_AXIS_LEFT_Y, 0.9))
	S.frame(app, 0)
	assert_eq(title.choice, Title.CHOICE_ONLINE, "stick down")
	assert_eq(S.screen_name(app), "Title", "moving does not pick")
	S.key_tap(app, KEY_ENTER)
	S.frame(app, 0)
	assert_eq(S.screen_name(app), "Online", "confirming ONLINE opens the private rooms")
	S.key_tap(app, KEY_ESCAPE)
	S.frame(app, 0)
	assert_eq(S.screen_name(app), "Title", "and Esc comes back")
	assert_eq(app.current_screen().choice, Title.CHOICE_ONLINE, "to the choice it left")
	S.tap(app, 30, JOY_BUTTON_DPAD_UP)
	S.frame(app, 0)
	S.tap(app, 30, JOY_BUTTON_A)
	S.frame(app, 0)
	assert_eq(S.screen_name(app), "Join")
	assert_eq(app.input, app.seats)
	assert_eq(app.seats.people(), 0, "the pad that picked LOCAL still presses A to join")


## The app remembers the last choice: back from the join screen the title shows LOCAL again; with ONLINE shown (and
## nothing started), the title reopens on ONLINE.
func test_the_title_remembers_the_last_choice() -> void:
	S.key_tap(app, KEY_ENTER)
	S.frame(app, 0)
	assert_eq(S.screen_name(app), "Join")
	S.key_tap(app, KEY_ESCAPE)
	S.frame(app, 0)
	assert_eq(S.screen_name(app), "Title")
	assert_eq(app.current_screen().choice, Title.CHOICE_LOCAL)
	S.key_tap(app, KEY_DOWN)
	S.frame(app, 0)
	app.show_title()
	assert_eq(app.current_screen().choice, Title.CHOICE_ONLINE)


func test_a_click_on_a_button_picks_it() -> void:
	app.current_screen()._unhandled_input(_click(ViewConfig.VERSUS_BUTTON.get_center()))
	assert_eq(S.screen_name(app), "Online", "ONLINE: a click picks it")
	assert_eq(app.title_choice, Title.CHOICE_ONLINE)
	app.show_title()
	app.current_screen()._unhandled_input(_click(ViewConfig.START_BUTTON.get_center()))
	assert_eq(S.screen_name(app), "Join")


## The title's layout: three buttons on the road, apart, clear of the car, the note band and the footer.
func test_the_two_buttons_fit_between_the_title_and_the_car() -> void:
	var buttons := TitleView.choice_buttons()
	var car := TitleView.car_box(Config.standard())
	var band := TitleView.note_band(app.atlas.font)
	assert_eq(buttons.size(), ViewConfig.TITLE_CHOICES.size())
	assert_false(buttons[0].intersects(buttons[1]) or buttons[1].intersects(buttons[2]))
	for button: Rect2i in buttons:
		assert_false(button.intersects(car), "%s clear of the car" % button)
		assert_false(button.intersects(band), "%s clear of the note" % button)
		assert_gt(button.position.y, ViewConfig.TITLE_TOP + ViewConfig.TEXT_HUGE)
		assert_gt(button.position.x, int(Config.standard().road_left) - 1, "on the road")
		assert_lt(button.end.x, int(Config.standard().road_right) + 1, "on the road")
	assert_false(band.intersects(car))
	assert_lt(band.end.y, car.position.y + 1)


## F11 and Alt+Enter switch the window between windowed and fullscreen, on every screen, and never reach the screens
## (Alt+Enter is no confirm press). Headless, the game's own window never changes mode on a screen, so the test gives
## the app a stand-in window (App.fullscreen_window), whose mode is what the toggle sets.
func test_f11_and_alt_enter_switch_fullscreen_on_every_screen() -> void:
	window = Window.new()
	app.fullscreen_window = window
	assert_eq(window.mode, Window.MODE_WINDOWED)
	S.key_tap(app, KEY_F11)
	assert_eq(window.mode, Window.MODE_FULLSCREEN)
	S.key_tap(app, KEY_F11)
	assert_eq(window.mode, Window.MODE_WINDOWED)
	S.key_tap(app, KEY_ENTER, true)
	assert_eq(window.mode, Window.MODE_FULLSCREEN, "Alt+Enter")
	S.frame(app, 0)
	assert_eq(S.screen_name(app), "Title", "Alt+Enter is not a confirm press")
	assert_eq(app.nav.take(), [] as Array[Vector2i], "nor a menu command")
	app.show_join()
	S.key_tap(app, KEY_F11)
	assert_eq(window.mode, Window.MODE_WINDOWED, "on the join screen")
	app.start_game()
	S.key_tap(app, KEY_KP_ENTER, true)
	assert_eq(window.mode, Window.MODE_FULLSCREEN, "in a game, keypad Enter with Alt")
	S.frame(app, 1)
	assert_eq(app.current_screen().world.phase, World.RUNNING, "the game took no press")
	var repeat := InputEventKey.new()
	repeat.physical_keycode = KEY_F11
	repeat.pressed = true
	repeat.echo = true
	app._input(repeat)
	assert_eq(window.mode, Window.MODE_FULLSCREEN, "a key repeat does not switch back")


func test_the_toggle_goes_between_window_and_fullscreen() -> void:
	assert_eq(App.toggled_window_mode(Window.MODE_WINDOWED), Window.MODE_FULLSCREEN)
	assert_eq(App.toggled_window_mode(Window.MODE_MAXIMIZED), Window.MODE_FULLSCREEN)
	assert_eq(App.toggled_window_mode(Window.MODE_FULLSCREEN), Window.MODE_WINDOWED)
	assert_eq(App.toggled_window_mode(Window.MODE_EXCLUSIVE_FULLSCREEN), Window.MODE_WINDOWED)
	assert_false(App.is_fullscreen_key(_plain_key(KEY_ENTER)), "Enter alone confirms")
	assert_false(App.is_fullscreen_key(_plain_key(KEY_F10)))


## Menu commands last one frame (App._process() drops what the screen did not take): the game screen takes none, and
## they must not pile up there or reach the next screen.
func test_menu_commands_last_one_frame() -> void:
	app.start_game()
	S.key_tap(app, KEY_DOWN)
	S.tap(app, 30, JOY_BUTTON_A)
	assert_eq(app.nav.commands.size(), 2)
	app._process(S.DT)
	assert_eq(app.nav.commands.size(), 0)


## After a local session the single-player game (App.start_game()) is as before, with the keyboard.
func test_single_player_after_versus_is_unchanged() -> void:
	app.show_join()
	S.tap(app, 30, JOY_BUTTON_A)
	S.frame(app, 0)
	S.tap(app, 30, JOY_BUTTON_START)
	S.frame(app, 0)
	assert_eq(S.screen_name(app), "Versus")
	app.show_title()
	assert_eq(app.input, app.solo)
	assert_eq(app.seats.people(), 0, "the title lets every pad go")
	app.start_game()
	S.frame(app, 0)
	assert_eq(S.screen_name(app), "Game")
	var game := app.current_screen()
	assert_eq(game.world.players.size(), 1)
	S.key(app, KEY_X, true)
	game.frame(30, S.DT * 30)
	S.key(app, KEY_X, false)
	assert_gt(game.world.player().speed, 0.0, "the keyboard drives it")
	assert_eq(game.cars.seat_colours, [] as Array[int], "its car is car_red")


# --- helpers ---------------------------------------------------------------------------------------------------------


static func _axis(device: int, axis: JoyAxis, value: float) -> InputEventJoypadMotion:
	var event := InputEventJoypadMotion.new()
	event.device = device
	event.axis = axis
	event.axis_value = value
	return event


static func _click(at: Vector2i) -> InputEventMouseButton:
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = Vector2(at)
	return click


static func _plain_key(code: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.pressed = true
	return event


## On the web (App.web_mode) the title waits for a key or a click before the menu music and before it takes input:
## browsers block sound until a gesture. A pad button is no gesture; nothing changes on the desktop.
func test_the_web_title_waits_for_a_key_or_a_click() -> void:
	assert_true(app.audio_unlocked, "desktop: nothing to wait for")
	assert_false((app.current_screen() as Title).waiting)
	app.web_mode = true
	app.audio_unlocked = false
	var title := app.show_title() as Title
	assert_true(title.waiting)
	assert_true(title.view.waiting)
	assert_true(ViewConfig.PROMPT_WEB.length() > 0 and ViewConfig.TEXT_MEDIUM % 8 == 0)
	# A pad button, Enter on the pad and a menu command are no gesture, and the title does not move.
	S.pad(app, PADS[0], JOY_BUTTON_A, true)
	S.pad(app, PADS[0], JOY_BUTTON_A, false)
	S.frame(app, 1)
	assert_eq(S.screen_name(app), "Title")
	assert_true(title.waiting, "a gamepad is no gesture")
	assert_false(app.audio_unlocked)
	# A key unlocks, and that key does not also pick LOCAL.
	S.key_tap(app, KEY_ENTER)
	title._unhandled_input(_key_event(KEY_ENTER))
	assert_false(title.waiting)
	assert_true(app.audio_unlocked)
	S.frame(app, 1)
	assert_eq(S.screen_name(app), "Title", "the unlocking press is not a confirm")
	S.key_tap(app, KEY_ENTER)
	S.frame(app, 1)
	assert_eq(S.screen_name(app), "Join", "then the title takes input")


func test_the_web_title_unlocks_with_a_click_and_stays_unlocked() -> void:
	app.web_mode = true
	app.audio_unlocked = false
	var title := app.show_title() as Title
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = Vector2(ViewConfig.START_BUTTON.position) + Vector2(2, 2)
	title._unhandled_input(click)
	assert_false(title.waiting)
	assert_eq(S.screen_name(app), "Title", "the click only unlocks")
	assert_eq(app.show_title().get("waiting"), false, "a second visit does not ask again")


## F is a fullscreen key on the web only (the browser keeps F11 and Alt+Enter); Esc never is.
func test_f_is_a_fullscreen_key_on_the_web_only() -> void:
	assert_false(App.is_fullscreen_key(_key_event(KEY_F)))
	assert_true(App.is_fullscreen_key(_key_event(KEY_F), true))
	assert_false(App.is_fullscreen_key(_key_event(KEY_ESCAPE), true))
	assert_true(App.is_fullscreen_key(_key_event(KEY_F11), true))
	window = Window.new()
	app.fullscreen_window = window
	app.web_mode = true
	S.key_tap(app, KEY_F)
	assert_eq(window.mode, Window.MODE_FULLSCREEN)
	S.key_tap(app, KEY_F)
	assert_eq(window.mode, Window.MODE_WINDOWED)
	S.key_tap(app, KEY_ESCAPE)
	assert_eq(window.mode, Window.MODE_WINDOWED, "Esc is BACK")
	for code: Key in [KEY_MINUS, KEY_EQUAL, KEY_M]:
		S.key_tap(app, code)
	assert_eq(window.mode, Window.MODE_WINDOWED, "the volume keys are not fullscreen")


func _key_event(code: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = true
	return event
