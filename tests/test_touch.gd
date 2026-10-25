extends "res://tests/test_case.gd"
## The touch controls (scripts/input/touch.gd, scripts/view/touch_view.gd): buttons that press the keyboard's keys, which controls show
## on which screen, when they turn on and off, and the app's wiring (a button down is the key down for Input and the menus).

const App := preload("res://scripts/app/app.gd")
const Touch := preload("res://scripts/input/touch.gd")
const ViewConfig := preload("res://scripts/view/view_config.gd")
const Helpers := preload("res://tests/screen_helpers.gd")
const Held := preload("res://scripts/input/held.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")

var touch: Touch
var events: Array[Vector2i] = []
var app: App


func before_each() -> void:
	events = []
	touch = Touch.new()
	touch.emit_key = func(code: int, pressed: bool) -> void: events.append(Vector2i(code, 1 if pressed else 0))
	touch.set_active(true)
	touch.set_mode(Touch.MODE_RACE)


func after_each() -> void:
	if app != null:
		Helpers.free_app(app)
		app = null
	Helpers.release([])


func _down(index: int, at: Vector2) -> bool:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.position = at
	event.pressed = true
	return touch.handle_event(event)


func _up(index: int, at: Vector2) -> bool:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.position = at
	event.pressed = false
	return touch.handle_event(event)


func _drag(index: int, at: Vector2) -> bool:
	var event := InputEventScreenDrag.new()
	event.index = index
	event.position = at
	return touch.handle_event(event)


func _centre(id: StringName, mode: int = Touch.MODE_RACE) -> Vector2:
	for button: Dictionary in Touch.buttons_of(mode):
		if button["id"] == id:
			return button["rect"].get_center() if button.has("rect") else button["centre"]
	return Vector2(-1000, -1000)


func test_the_buttons_of_each_mode_fit_the_view_and_do_not_overlap() -> void:
	for mode: int in [Touch.MODE_RACE, Touch.MODE_MENU]:
		var buttons := Touch.buttons_of(mode)
		assert_gt(buttons.size(), 5, "mode %d has buttons" % mode)
		for button: Dictionary in buttons:
			var box: Rect2 = button["rect"] if button.has("rect") else Rect2(
				button["centre"] - Vector2.ONE * float(button["radius"]), Vector2.ONE * 2.0 * float(button["radius"])
			)
			assert_true(Rect2(0, 0, ViewConfig.VIEW_W, ViewConfig.VIEW_H).encloses(box), "%s fits the view" % button["id"])
		for i in buttons.size():
			for j in range(i + 1, buttons.size()):
				var a := _centre(buttons[i]["id"], mode)
				# A button's own centre always selects it, so no other button may claim that point.
				touch.set_mode(mode)
				assert_eq(touch.button_at(a), buttons[i]["id"], "%s wins its own centre" % buttons[i]["id"])
				assert_ne(buttons[i]["id"], buttons[j]["id"], "ids are unique")


func test_a_touch_presses_its_key_and_lifting_it_lets_go() -> void:
	assert_true(_down(0, _centre(Touch.LEFT)), "a touch on a button is taken")
	assert_eq(events, [Vector2i(KEY_LEFT, 1)])
	assert_true(touch.is_held(Touch.LEFT))
	assert_true(_up(0, _centre(Touch.LEFT)))
	assert_eq(events, [Vector2i(KEY_LEFT, 1), Vector2i(KEY_LEFT, 0)])
	assert_false(touch.is_held(Touch.LEFT))


func test_a_touch_beside_the_buttons_is_left_to_the_screen() -> void:
	assert_false(_down(0, Vector2(320, 180)), "the middle of the road is no button")
	assert_false(_up(0, Vector2(320, 180)))
	assert_eq(events.size(), 0)


func test_several_fingers_hold_several_buttons() -> void:
	_down(0, _centre(Touch.RIGHT))
	_down(1, _centre(Touch.NITRO))
	_down(2, _centre(Touch.GAS))
	assert_true(touch.is_held(Touch.RIGHT) and touch.is_held(Touch.NITRO) and touch.is_held(Touch.GAS))
	_up(1, _centre(Touch.NITRO))
	assert_false(touch.is_held(Touch.NITRO))
	assert_true(touch.is_held(Touch.RIGHT) and touch.is_held(Touch.GAS), "the others stay down")


func test_two_fingers_on_one_button_let_go_only_when_both_lift() -> void:
	_down(0, _centre(Touch.GAS))
	_down(1, _centre(Touch.GAS))
	assert_eq(events.size(), 1, "one key down")
	_up(0, _centre(Touch.GAS))
	assert_true(touch.is_held(Touch.GAS))
	_up(1, _centre(Touch.GAS))
	assert_false(touch.is_held(Touch.GAS))
	assert_eq(events, [Vector2i(KEY_UP, 1), Vector2i(KEY_UP, 0)])


func test_a_finger_sliding_from_left_to_right_changes_the_steering() -> void:
	_down(0, _centre(Touch.LEFT))
	assert_true(_drag(0, _centre(Touch.RIGHT)))
	assert_false(touch.is_held(Touch.LEFT))
	assert_true(touch.is_held(Touch.RIGHT))
	assert_true(_drag(0, Vector2(320, 100)), "sliding off the buttons lets go")
	assert_false(touch.is_held(Touch.RIGHT))
	assert_eq(events, [Vector2i(KEY_LEFT, 1), Vector2i(KEY_LEFT, 0), Vector2i(KEY_RIGHT, 1), Vector2i(KEY_RIGHT, 0)])


func test_a_touch_a_little_off_a_button_still_counts() -> void:
	var gas: Vector2 = _centre(Touch.GAS)
	assert_true(_down(0, gas - Vector2(28.0 + Touch.SLOP - 1.0, 0)), "inside the slop")
	assert_false(_down(1, Vector2(400, 200)), "far outside")


func test_changing_the_mode_lets_go_of_everything() -> void:
	_down(0, _centre(Touch.LEFT))
	touch.set_mode(Touch.MODE_MENU)
	assert_false(touch.is_held(Touch.LEFT))
	assert_eq(events.back(), Vector2i(KEY_LEFT, 0))
	assert_eq(touch.button_at(_centre(Touch.BRAKE)), &"", "a race button is gone in the menu")


func test_a_real_key_or_pad_turns_the_controls_off_and_a_touch_on() -> void:
	_down(0, _centre(Touch.LEFT))
	var key := InputEventKey.new()
	key.physical_keycode = KEY_SPACE
	key.pressed = true
	touch.handle_event(key)
	assert_false(touch.active, "a keyboard: no controls")
	assert_false(touch.is_held(Touch.LEFT), "and nothing stays held")
	assert_eq(touch.buttons().size(), 0)
	_down(1, Vector2(320, 180))
	assert_true(touch.active, "a finger brings them back")


func test_keys_the_buttons_made_do_not_count_as_a_keyboard() -> void:
	_down(0, _centre(Touch.OK))
	var key := InputEventKey.new()
	key.physical_keycode = KEY_ENTER
	key.pressed = true
	touch.handle_event(key)
	assert_true(touch.active, "the Enter the OK button made")
	touch.handle_event(key)
	assert_false(touch.active, "a second Enter is the keyboard's")
	touch.set_active(true)
	var pad := InputEventJoypadButton.new()
	pad.pressed = true
	touch.handle_event(pad)
	assert_false(touch.active, "a pad button does")


func test_detect_follows_the_page() -> void:
	assert_true(Touch.detect(true))
	assert_eq(Touch.detect(false), OS.has_feature("mobile"))


# --- The app's wiring ---------------------------------------------------------------------------------------------------------------


func _boot_touch() -> void:
	app = Helpers.boot(7)
	app.touch.set_active(true)
	app.touch.emit_key = _deliver_key


func test_the_controls_show_by_screen() -> void:
	_boot_touch()
	assert_eq(app.touch_mode(), Touch.MODE_MENU, "title")
	app.start_game()
	assert_eq(app.touch_mode(), Touch.MODE_RACE, "game")
	app.show_join()
	assert_eq(app.touch_mode(), Touch.MODE_MENU, "join")
	app.show_title()
	app.web_mode = true
	app.audio_unlocked = false
	assert_eq(app.touch_mode(), Touch.MODE_NONE, "the web title waits for the first tap")


func test_a_button_is_the_keyboard_key_for_input_and_the_menus() -> void:
	_boot_touch()
	app.start_game()
	app.touch.set_mode(Touch.MODE_RACE)
	var events_in := app.touch
	events_in.handle_event(_touch_event(_centre(Touch.LEFT), true))
	events_in.handle_event(_touch_event(_centre(Touch.NITRO), true, 1))
	assert_true(Input.is_action_pressed("kb_left"), "left is held")
	assert_true(Input.is_action_pressed("kb_nitro"), "nitro is held")
	var mask := app.input.held()
	assert_true((mask & Held.LEFT) != 0 and (mask & Held.NITRO) != 0 and (mask & Held.ACCEL) != 0, "the game reads them as held controls")
	events_in.handle_event(_touch_event(_centre(Touch.LEFT), false))
	events_in.handle_event(_touch_event(_centre(Touch.NITRO), false, 1))
	assert_false(Input.is_action_pressed("kb_left"))
	assert_eq(app.input.held(), 0)


func test_pause_and_ok_buttons_make_presses() -> void:
	_boot_touch()
	app.start_game()
	app.touch.set_mode(Touch.MODE_RACE)
	app.touch.handle_event(_touch_event(_centre(Touch.PAUSE), true))
	app.touch.handle_event(_touch_event(_centre(Touch.PAUSE), false))
	assert_true(PlayerInput.pause(app.input.take_presses()), "P is a pause press")


func test_the_menu_buttons_make_menu_commands() -> void:
	_boot_touch()
	app.touch.set_mode(Touch.MODE_MENU)
	app.touch.handle_event(_touch_event(_centre(Touch.DOWN, Touch.MODE_MENU), true))
	app.touch.handle_event(_touch_event(_centre(Touch.DOWN, Touch.MODE_MENU), false))
	var commands := app.nav.take()
	assert_eq(commands.size(), 1)
	assert_eq(commands[0], Vector2i(-1, 2), "the keyboard's Down")
	app.touch.handle_event(_touch_event(_centre(Touch.OK, Touch.MODE_MENU), true))
	app.touch.handle_event(_touch_event(_centre(Touch.OK, Touch.MODE_MENU), false))
	var accept := app.nav.take()
	assert_eq(accept.size(), 1)
	assert_eq(accept[0].y, 5, "Accept")


func test_the_title_asks_for_taps_on_a_touch_device() -> void:
	_boot_touch()
	var title := app.current_screen()
	title.frame(0, 1.0 / 60.0)
	assert_true(title.view.touch, "the title knows it is a touch device")
	app.touch.set_active(false)
	title.frame(0, 1.0 / 60.0)
	assert_false(title.view.touch)


func _touch_event(at: Vector2, pressed: bool, index: int = 0) -> InputEventScreenTouch:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.position = at
	event.pressed = pressed
	return event


## What the engine does with the key a button makes: Input's state, then App._input() (the runner's tree delivers nothing).
func _deliver_key(code: int, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = code as Key
	event.physical_keycode = code as Key
	event.pressed = pressed
	Helpers.deliver(app, event)


func test_the_app_turns_a_button_into_a_key_event_of_the_touch_device() -> void:
	app = Helpers.boot(7)
	app._touch_key(KEY_LEFT, true)
	Input.flush_buffered_events()
	assert_true(Input.is_action_pressed("kb_left"), "Input sees the key")
	app._touch_key(KEY_LEFT, false)
	Input.flush_buffered_events()
	assert_false(Input.is_action_pressed("kb_left"))
