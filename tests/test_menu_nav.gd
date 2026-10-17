extends "res://tests/test_case.gd"
## Menu commands (scripts/input/nav.gd, B2): keys by physical key and joypad buttons each make a command with the
## device it came from, in order; a key repeat or a release makes none; the left stick makes one when it crosses the
## threshold, and another only after it has come back.

const Nav := preload("res://scripts/input/nav.gd")

var nav: Nav


func before_each() -> void:
	nav = Nav.new()


func test_keys_make_keyboard_commands() -> void:
	var expected := {
		KEY_UP: Nav.UP, KEY_W: Nav.UP, KEY_DOWN: Nav.DOWN, KEY_S: Nav.DOWN, KEY_LEFT: Nav.LEFT, KEY_A: Nav.LEFT,
		KEY_RIGHT: Nav.RIGHT, KEY_D: Nav.RIGHT, KEY_ENTER: Nav.ACCEPT, KEY_KP_ENTER: Nav.ACCEPT,
		KEY_SPACE: Nav.ACCEPT, KEY_ESCAPE: Nav.BACK,
	}
	for code: Key in expected:
		assert_eq(nav.handle_event(_key(code, true)), expected[code], OS.get_keycode_string(code))
	assert_eq(nav.take().size(), expected.size())
	for code: Key in [KEY_X, KEY_P, KEY_F11, KEY_Z]:
		assert_eq(nav.handle_event(_key(code, true)), 0, "%s makes no command" % OS.get_keycode_string(code))
	assert_eq(nav.handle_event(_key(KEY_ENTER, false)), 0, "a release")
	var repeat := _key(KEY_DOWN, true)
	repeat.echo = true
	assert_eq(nav.handle_event(repeat), 0, "a repeat")
	assert_eq(nav.take(), [] as Array[Vector2i])


func test_pad_buttons_make_commands_of_their_device() -> void:
	var expected := {
		JOY_BUTTON_DPAD_UP: Nav.UP, JOY_BUTTON_DPAD_DOWN: Nav.DOWN, JOY_BUTTON_DPAD_LEFT: Nav.LEFT,
		JOY_BUTTON_DPAD_RIGHT: Nav.RIGHT, JOY_BUTTON_A: Nav.ACCEPT, JOY_BUTTON_B: Nav.BACK, JOY_BUTTON_START: Nav.START,
		JOY_BUTTON_BACK: Nav.SELECT,
	}
	var order: Array[Vector2i] = []
	for button: JoyButton in expected:
		nav.handle_event(_button(4, button, true))
		order.append(Vector2i(4, expected[button]))
	nav.handle_event(_button(9, JOY_BUTTON_X, true))
	nav.handle_event(_button(9, JOY_BUTTON_A, false))
	nav.handle_event(_key(KEY_ESCAPE, true))
	order.append(Vector2i(Nav.KEYBOARD, Nav.BACK))
	assert_eq(nav.take(), order, "in order, X and a release make none")


func test_the_stick_makes_one_command_per_push() -> void:
	nav.handle_event(_axis(3, JOY_AXIS_LEFT_Y, -0.4))
	assert_eq(nav.take(), [] as Array[Vector2i], "inside the threshold")
	nav.handle_event(_axis(3, JOY_AXIS_LEFT_Y, -0.8))
	nav.handle_event(_axis(3, JOY_AXIS_LEFT_Y, -1.0))
	nav.handle_event(_axis(3, JOY_AXIS_LEFT_Y, -0.4))
	nav.handle_event(_axis(3, JOY_AXIS_LEFT_Y, -0.7))
	assert_eq(nav.take(), [Vector2i(3, Nav.UP)] as Array[Vector2i], "held, or back only to 0.4: one")
	nav.handle_event(_axis(3, JOY_AXIS_LEFT_Y, 0.1))
	nav.handle_event(_axis(3, JOY_AXIS_LEFT_Y, 0.9))
	nav.handle_event(_axis(3, JOY_AXIS_LEFT_X, 0.9))
	nav.handle_event(_axis(3, JOY_AXIS_LEFT_X, -0.9))
	nav.handle_event(_axis(3, JOY_AXIS_RIGHT_X, 0.9))
	nav.handle_event(_axis(5, JOY_AXIS_LEFT_X, 0.9))
	assert_eq(nav.take(), [
		Vector2i(3, Nav.DOWN), Vector2i(3, Nav.RIGHT), Vector2i(3, Nav.LEFT), Vector2i(5, Nav.RIGHT)
	] as Array[Vector2i], "back to rest, then down; a flick right then left; the right stick makes none")


func test_a_pad_that_goes_away_starts_afresh() -> void:
	nav.handle_event(_axis(6, JOY_AXIS_LEFT_X, 0.9))
	nav.connection_changed(6, false)
	nav.handle_event(_axis(6, JOY_AXIS_LEFT_X, 0.9))
	assert_eq(nav.take(), [Vector2i(6, Nav.RIGHT), Vector2i(6, Nav.RIGHT)] as Array[Vector2i])
	nav.handle_event(_button(6, JOY_BUTTON_A, true))
	nav.clear()
	assert_eq(nav.take(), [] as Array[Vector2i])


# --- helpers ---------------------------------------------------------------------------------------------------------


static func _key(code: Key, pressed: bool) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.pressed = pressed
	return event


static func _button(device: int, button: JoyButton, pressed: bool) -> InputEventJoypadButton:
	var event := InputEventJoypadButton.new()
	event.device = device
	event.button_index = button
	event.pressed = pressed
	return event


static func _axis(device: int, axis: JoyAxis, value: float) -> InputEventJoypadMotion:
	var event := InputEventJoypadMotion.new()
	event.device = device
	event.axis = axis
	event.axis_value = value
	return event
