extends RefCounted
## Helpers for the tests that drive the app's screens (B2), not a test file. They boot a real App from
## scenes/boot.tscn as tests/test_app.gd does (the runner's tree delivers no events and no _ready(): start() is
## called here), and deliver key and joypad events as the engine would: Input's state first
## (Input.parse_input_event()), then App._input(). release() lets go of Input's state afterwards.

const App := preload("res://scripts/app/app.gd")

const BOOT := "res://scenes/boot.tscn"
const DT := 1.0 / 60.0
const BUTTONS: Array[JoyButton] = [
	JOY_BUTTON_A, JOY_BUTTON_B, JOY_BUTTON_START, JOY_BUTTON_BACK, JOY_BUTTON_DPAD_UP, JOY_BUTTON_DPAD_DOWN,
	JOY_BUTTON_DPAD_LEFT, JOY_BUTTON_DPAD_RIGHT,
]


## An App in the runner's root, booted, on the title.
static func boot(seed_value: int) -> App:
	var app := (load(BOOT) as PackedScene).instantiate() as App
	app.seed_override = seed_value
	# The start countdown of a race is tested on its own: screen tests race from the first step.
	app.tuning.set_value("race_start_ticks", 0.0)
	(Engine.get_main_loop() as SceneTree).root.add_child(app)
	app.start()
	return app


static func free_app(app: App) -> void:
	if app != null:
		app.get_parent().remove_child(app)
		app.free()


static func screen_name(app: App) -> String:
	return String(app.current_screen().name)


## One frame of the current screen with `steps` fixed steps, as App._process() runs it.
static func frame(app: App, steps: int = 1) -> void:
	app.current_screen().frame(steps, DT * steps)


static func deliver(app: App, event: InputEvent) -> void:
	Input.parse_input_event(event)
	Input.flush_buffered_events()
	app._input(event)


static func pad(app: App, device: int, button: JoyButton, pressed: bool) -> void:
	var event := InputEventJoypadButton.new()
	event.device = device
	event.button_index = button
	event.pressed = pressed
	event.pressure = 1.0 if pressed else 0.0
	deliver(app, event)


## A button pressed and let go.
static func tap(app: App, device: int, button: JoyButton) -> void:
	pad(app, device, button, true)
	pad(app, device, button, false)


static func key(app: App, code: Key, pressed: bool = true, alt: bool = false) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = pressed
	event.alt_pressed = alt
	deliver(app, event)


## A key pressed and let go.
static func key_tap(app: App, code: Key, alt: bool = false) -> void:
	key(app, code, true, alt)
	key(app, code, false, alt)


## Lets go of every button and stick of these pads, and of the keys the tests press, in Input's state.
static func release(devices: Array[int]) -> void:
	for device: int in devices:
		for button: JoyButton in BUTTONS:
			var event := InputEventJoypadButton.new()
			event.device = device
			event.button_index = button
			Input.parse_input_event(event)
		for axis: JoyAxis in [JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y]:
			var motion := InputEventJoypadMotion.new()
			motion.device = device
			motion.axis = axis
			Input.parse_input_event(motion)
	for code: Key in [
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE, KEY_ESCAPE, KEY_P, KEY_F11, KEY_DOWN, KEY_UP, KEY_LEFT, KEY_RIGHT, KEY_X, KEY_Z
	]:
		var up := InputEventKey.new()
		up.physical_keycode = code
		up.keycode = code
		Input.parse_input_event(up)
	Input.flush_buffered_events()
