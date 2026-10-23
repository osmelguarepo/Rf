extends RefCounted
## Menu commands (B2): what a key or a joypad button means on the menu screens (the title's mode choice, the join
## screen, the versus pause and results), each with the device it came from. The game's bytes do not come from here:
## held controls and the pause and confirm presses of a race are local_input.gd's and seats.gd's.
##
## App._input() hands every event to handle_event(), which queues commands in order; a screen takes them with take()
## on its next frame. App._switch_to() clears the queue, so a command never reaches the next screen.
##
##   Keyboard (device KEYBOARD)     Joypad (its own device)
##   Up / W        UP               D-pad up, left stick up        UP
##   Down / S      DOWN             D-pad down, left stick down    DOWN
##   Left / A      LEFT             D-pad left, left stick left    LEFT
##   Right / D     RIGHT            D-pad right, left stick right  RIGHT
##   Enter, Space  ACCEPT           A                              ACCEPT
##   Esc           BACK             B                              BACK
##                                  Start                          START
##                                  Back (Select, View)            SELECT
##
## Keys count by physical key, as keyboard.gd's do; a key repeat is not a command. A stick makes a command when it
## crosses STICK_THRESHOLD towards a direction, and again only after it has come back inside STICK_RELEASE (so a
## stick resting near the threshold does not chatter).

const Pads := preload("res://scripts/input/pads.gd")

## The device of keyboard commands (joypad devices are 0 and up).
const KEYBOARD := -1

const UP := 1
const DOWN := 2
const LEFT := 3
const RIGHT := 4
const ACCEPT := 5
const BACK := 6
const START := 7
const SELECT := 8
const NAMES := ["", "up", "down", "left", "right", "accept", "back", "start", "select"]

## A stick counts as a direction beyond this (Pads.STICK_THRESHOLD, the driving threshold), and lets go of it inside
## STICK_RELEASE.
const STICK_THRESHOLD := Pads.STICK_THRESHOLD
const STICK_RELEASE := 0.3

const KEYS := {
	KEY_UP: UP, KEY_W: UP,
	KEY_DOWN: DOWN, KEY_S: DOWN,
	KEY_LEFT: LEFT, KEY_A: LEFT,
	KEY_RIGHT: RIGHT, KEY_D: RIGHT,
	KEY_ENTER: ACCEPT, KEY_KP_ENTER: ACCEPT, KEY_SPACE: ACCEPT,
	KEY_ESCAPE: BACK,
	KEY_BACKSPACE: SELECT,
}
const BUTTONS := {
	JOY_BUTTON_DPAD_UP: UP,
	JOY_BUTTON_DPAD_DOWN: DOWN,
	JOY_BUTTON_DPAD_LEFT: LEFT,
	JOY_BUTTON_DPAD_RIGHT: RIGHT,
	JOY_BUTTON_A: ACCEPT,
	JOY_BUTTON_B: BACK,
	JOY_BUTTON_START: START,
	JOY_BUTTON_BACK: SELECT,
}

## Commands not taken yet, oldest first: Vector2i(device, command).
var commands: Array[Vector2i] = []
## Per joypad device, the left stick's direction on each axis (-1, 0, 1) as last seen: Vector2i(x, y).
var _stick: Dictionary = {}


## Queues the command an event makes, if any. Returns it (0 for none).
func handle_event(event: InputEvent) -> int:
	var command := 0
	var device := KEYBOARD
	if event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and not key.echo:
			var code := key.physical_keycode if key.physical_keycode != KEY_NONE else key.keycode
			command = KEYS.get(code, 0)
	elif event is InputEventJoypadButton:
		var button := event as InputEventJoypadButton
		device = button.device
		if button.pressed:
			command = BUTTONS.get(button.button_index, 0)
	elif event is InputEventJoypadMotion:
		var motion := event as InputEventJoypadMotion
		device = motion.device
		command = _stick_command(motion)
	if command != 0:
		commands.append(Vector2i(device, command))
	return command


## Takes every queued command, oldest first.
func take() -> Array[Vector2i]:
	var out := commands
	commands = []
	return out


func clear() -> void:
	commands = []


## A joypad went away: forget its stick, so it starts afresh if it comes back.
func connection_changed(device: int, connected: bool) -> void:
	if not connected:
		_stick.erase(device)


## The command a left-stick motion makes: a direction when the axis crosses STICK_THRESHOLD from rest (or from the
## other side). Other axes make none.
func _stick_command(motion: InputEventJoypadMotion) -> int:
	if motion.axis != JOY_AXIS_LEFT_X and motion.axis != JOY_AXIS_LEFT_Y:
		return 0
	var last: Vector2i = _stick.get(motion.device, Vector2i.ZERO)
	var vertical := motion.axis == JOY_AXIS_LEFT_Y
	var before := last.y if vertical else last.x
	var value := motion.axis_value
	var now := before
	if value > STICK_THRESHOLD:
		now = 1
	elif value < -STICK_THRESHOLD:
		now = -1
	elif absf(value) < STICK_RELEASE:
		now = 0
	if vertical:
		last.y = now
	else:
		last.x = now
	_stick[motion.device] = last
	if now == before or now == 0:
		return 0
	if vertical:
		return DOWN if now > 0 else UP
	return RIGHT if now > 0 else LEFT
