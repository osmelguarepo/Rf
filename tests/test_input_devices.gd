extends "res://tests/test_case.gd"
## The input layer (scripts/input/, docs/GODOT_PLAN.md §5): the keyboard's input map built in code, joypads read
## device by device, and the single-player byte with latched presses. Events go through Input.parse_input_event()
## and Input.flush_buffered_events(), so Input's state is the real one; after_each() lets go of everything.

const PlayerInput := preload("res://scripts/sim/player_input.gd")
const Held := preload("res://scripts/input/held.gd")
const Keyboard := preload("res://scripts/input/keyboard.gd")
const Pads := preload("res://scripts/input/pads.gd")
const LocalInput := preload("res://scripts/input/local_input.gd")

## Joypad devices the tests use.
const PAD := 3
const OTHER_PAD := 5
const PAD_BUTTONS := [
	JOY_BUTTON_A, JOY_BUTTON_B, JOY_BUTTON_START, JOY_BUTTON_DPAD_UP, JOY_BUTTON_DPAD_DOWN, JOY_BUTTON_DPAD_LEFT,
	JOY_BUTTON_DPAD_RIGHT,
]

var router: LocalInput


func before_all() -> void:
	Keyboard.build_input_map()


func before_each() -> void:
	router = LocalInput.new()


func after_each() -> void:
	for action: String in Keyboard.ACTIONS:
		for code: int in Keyboard.ACTIONS[action]:
			Input.parse_input_event(_key(code, false))
	for device: int in [PAD, OTHER_PAD]:
		for button: int in PAD_BUTTONS:
			Input.parse_input_event(_button(device, button, false))
		for axis: int in [JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y]:
			Input.parse_input_event(_axis(device, axis, 0.0))
	Input.flush_buffered_events()


func test_the_input_map_is_built_in_code_with_physical_keys() -> void:
	var expected := {
		"kb_throttle": [KEY_UP, KEY_W, KEY_Z],
		"kb_high_gear": [KEY_X],
		"kb_brake": [KEY_DOWN, KEY_S],
		"kb_left": [KEY_LEFT, KEY_A],
		"kb_right": [KEY_RIGHT, KEY_D],
		"kb_confirm": [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE],
		"kb_pause": [KEY_ESCAPE, KEY_P],
	}
	var found := {}
	var not_keys: Array = []
	for action: String in expected:
		assert_true(InputMap.has_action(action), action)
		var keys: Array = []
		for event: InputEvent in InputMap.action_get_events(action):
			var key := event as InputEventKey
			if key == null or key.keycode != KEY_NONE:
				not_keys.append("%s: %s" % [action, event.as_text()])
			else:
				keys.append(int(key.physical_keycode))
		found[action] = keys
	assert_eq(found, expected, "physical keys per action")
	assert_eq(not_keys, [], "events that are not physical keys (no joypad events: pads are read per device)")


func test_x_holds_high_gear_and_throttle() -> void:
	_press_key(KEY_X)
	assert_eq(Keyboard.held(), Held.ACCEL | Held.HIGH_GEAR)
	assert_eq(router.step_byte(), PlayerInput.encode(true, false, 0, true))


func test_up_w_and_z_are_throttle_in_low_gear() -> void:
	for code: int in [KEY_UP, KEY_W, KEY_Z]:
		_press_key(code)
		assert_eq(Keyboard.held(), Held.ACCEL, OS.get_keycode_string(code))
		_release_key(code)
	assert_eq(Keyboard.held(), 0)


func test_down_and_s_brake() -> void:
	_press_key(KEY_S)
	assert_eq(router.step_byte(), PlayerInput.encode(false, true, 0, false))
	_release_key(KEY_S)
	_press_key(KEY_DOWN)
	assert_eq(Keyboard.held(), Held.BRAKE)


func test_steering_left_right_and_both() -> void:
	_press_key(KEY_A)
	assert_eq(PlayerInput.steer_of(router.step_byte()), -1)
	_press_key(KEY_RIGHT)
	assert_eq(PlayerInput.steer_of(router.step_byte()), 0, "left and right together cancel out")
	_release_key(KEY_A)
	assert_eq(PlayerInput.steer_of(router.step_byte()), 1)


func test_enter_space_and_escape_p_are_presses_latched_until_a_step() -> void:
	for code: int in [KEY_ENTER, KEY_SPACE, KEY_KP_ENTER]:
		_tap_key(code)
		var byte := router.step_byte()
		assert_true(PlayerInput.confirm(byte), OS.get_keycode_string(code))
		assert_false(PlayerInput.confirm(router.step_byte()), "taken by the first step")
	for code: int in [KEY_ESCAPE, KEY_P]:
		_tap_key(code)
		assert_eq(router.take_presses(), PlayerInput.PAUSE, OS.get_keycode_string(code))
	assert_eq(router.take_presses(), 0)


## A press survives frames without a step (the latch), and two presses before a step make one byte with both.
func test_presses_wait_for_a_step_and_combine() -> void:
	_tap_key(KEY_ENTER)
	_tap_key(KEY_ESCAPE)
	assert_eq(router.pending, PlayerInput.CONFIRM | PlayerInput.PAUSE)
	var byte := router.step_byte()
	assert_true(PlayerInput.confirm(byte) and PlayerInput.pause(byte))
	assert_eq(router.pending, 0)


func test_key_repeats_and_releases_are_not_presses() -> void:
	var repeat := _key(KEY_ENTER, true)
	repeat.echo = true
	assert_eq(Keyboard.presses_of(repeat), 0)
	assert_eq(Keyboard.presses_of(_key(KEY_ENTER, false)), 0)
	assert_eq(Keyboard.presses_of(_key(KEY_ENTER, true)), PlayerInput.CONFIRM)


func test_a_pad_is_read_on_its_own_device() -> void:
	_send(_button(PAD, JOY_BUTTON_A, true))
	assert_eq(Pads.held_of(PAD), Held.ACCEL | Held.HIGH_GEAR, "A: high gear and throttle")
	assert_eq(Pads.held_of(OTHER_PAD), 0, "another device sees nothing")
	_send(_button(PAD, JOY_BUTTON_A, false))
	_send(_button(PAD, JOY_BUTTON_B, true))
	assert_eq(Pads.held_of(PAD), Held.ACCEL, "B: throttle in low gear")
	_send(_button(PAD, JOY_BUTTON_DPAD_DOWN, true))
	_send(_button(PAD, JOY_BUTTON_DPAD_LEFT, true))
	assert_eq(Pads.held_of(PAD), Held.ACCEL | Held.BRAKE | Held.LEFT)
	_send(_button(PAD, JOY_BUTTON_DPAD_UP, true))
	_send(_button(PAD, JOY_BUTTON_DPAD_RIGHT, true))
	assert_eq(Pads.held_of(PAD), Held.ACCEL | Held.BRAKE | Held.LEFT | Held.RIGHT)


func test_the_left_stick_counts_beyond_half() -> void:
	_send(_axis(PAD, JOY_AXIS_LEFT_X, -0.5))
	_send(_axis(PAD, JOY_AXIS_LEFT_Y, 0.5))
	assert_eq(Pads.held_of(PAD), 0, "exactly 0.5 is not a direction")
	_send(_axis(PAD, JOY_AXIS_LEFT_X, -0.6))
	assert_eq(Pads.held_of(PAD), Held.LEFT)
	_send(_axis(PAD, JOY_AXIS_LEFT_X, 0.6))
	_send(_axis(PAD, JOY_AXIS_LEFT_Y, -0.6))
	assert_eq(Pads.held_of(PAD), Held.RIGHT | Held.ACCEL, "stick up is throttle")
	_send(_axis(PAD, JOY_AXIS_LEFT_Y, 0.6))
	assert_eq(Pads.held_of(PAD), Held.RIGHT | Held.BRAKE, "stick down is brake")


func test_pad_a_confirms_and_start_pauses_and_confirms() -> void:
	assert_eq(Pads.press_bits(_button(PAD, JOY_BUTTON_A, true)), PlayerInput.CONFIRM)
	assert_eq(Pads.press_bits(_button(PAD, JOY_BUTTON_START, true)), PlayerInput.PAUSE | PlayerInput.CONFIRM)
	assert_eq(Pads.press_bits(_button(PAD, JOY_BUTTON_B, true)), 0)
	assert_eq(Pads.press_bits(_button(PAD, JOY_BUTTON_START, false)), 0, "a release is not a press")
	_send(_button(PAD, JOY_BUTTON_START, true))
	assert_eq(router.take_presses(), PlayerInput.PAUSE | PlayerInput.CONFIRM)


## Single player: any pad and the keyboard together. Devices become known from their events.
func test_every_pad_and_the_keyboard_drive_the_single_player() -> void:
	assert_false(router.pads.devices.has(OTHER_PAD), "not known before its first event")
	_send(_button(OTHER_PAD, JOY_BUTTON_DPAD_LEFT, true))
	assert_true(router.pads.devices.has(OTHER_PAD), "known from its event")
	assert_eq(PlayerInput.steer_of(router.step_byte()), -1)
	_press_key(KEY_RIGHT)
	assert_eq(PlayerInput.steer_of(router.step_byte()), 0, "pad left and key right cancel out")
	_send(_button(PAD, JOY_BUTTON_A, true))
	assert_true(router.pads.devices.has(PAD) and router.pads.devices.has(OTHER_PAD))
	var byte := router.step_byte()
	assert_true(PlayerInput.high_gear(byte) and PlayerInput.accel(byte))


func test_a_disconnected_pad_is_no_longer_polled() -> void:
	router.pads.connection_changed(7, true)
	assert_true(router.pads.devices.has(7))
	router.pads.connection_changed(7, false)
	assert_false(router.pads.devices.has(7))


## Steering bits merge as left/right flags, never as bytes: OR-ing the byte's "left" (0) with "none" (1) would read
## as "none".
func test_held_bits_make_the_byte() -> void:
	assert_eq(Held.to_byte(0), PlayerInput.NONE)
	assert_eq(Held.to_byte(Held.LEFT), PlayerInput.encode(false, false, -1, false))
	assert_eq(Held.to_byte(Held.LEFT | Held.RIGHT), PlayerInput.NONE)
	assert_eq(Held.to_byte(Held.ACCEL | Held.HIGH_GEAR, PlayerInput.PAUSE), PlayerInput.encode(true, false, 0, true, true))
	assert_eq(Held.to_byte(0, PlayerInput.ACCEL), PlayerInput.NONE, "only presses come from the second argument")


func test_a_program_press_is_latched_like_a_key() -> void:
	router.press(PlayerInput.PAUSE)
	router.press(PlayerInput.PAUSE)
	assert_eq(router.step_bytes(1), PackedByteArray([PlayerInput.NONE | PlayerInput.PAUSE]))
	assert_eq(router.step_bytes(3), PackedByteArray([PlayerInput.NONE, PlayerInput.NONE, PlayerInput.NONE]))
	router.press(PlayerInput.CONFIRM)
	router.clear_presses()
	assert_eq(router.take_presses(), 0)


# --- helpers ---------------------------------------------------------------------------------------------------------


static func _key(code: int, pressed: bool) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = code as Key
	event.keycode = code as Key
	event.pressed = pressed
	return event


static func _button(device: int, button: int, pressed: bool) -> InputEventJoypadButton:
	var event := InputEventJoypadButton.new()
	event.device = device
	event.button_index = button as JoyButton
	event.pressed = pressed
	return event


static func _axis(device: int, axis: int, value: float) -> InputEventJoypadMotion:
	var event := InputEventJoypadMotion.new()
	event.device = device
	event.axis = axis as JoyAxis
	event.axis_value = value
	return event


## Delivers an event as the engine would: Input's state, then the app's handler (app.gd forwards _input events).
func _send(event: InputEvent) -> void:
	Input.parse_input_event(event)
	Input.flush_buffered_events()
	router.handle_event(event)


func _press_key(code: int) -> void:
	_send(_key(code, true))


func _release_key(code: int) -> void:
	_send(_key(code, false))


func _tap_key(code: int) -> void:
	_press_key(code)
	_release_key(code)
