extends RefCounted
## The keyboard (src/input.ts in the Phaser version, docs/GODOT_PLAN.md §5).
##
## The input map is built in code by build_input_map(): one action per control, bound to physical key codes, so
## the controls stay where they are on any keyboard layout (Phaser used KeyboardEvent.code). The actions hold only
## keys: joypads are read device by device in pads.gd, never through merged InputMap actions.
##
##   Up / W / Z    throttle            X             nitro and throttle (held)
##   Down / S      brake               Left / A      steer left
##   Right / D     steer right         Enter / Space confirm (press)
##   Esc / P       pause (press)
##
## Held controls are read when a step needs them (held()). Presses come from key events (presses_of()), so a press
## shorter than a frame is not lost; key repeats are ignored.

const Held := preload("res://scripts/input/held.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")

const THROTTLE := "kb_throttle"
const NITRO := "kb_nitro"
const BRAKE := "kb_brake"
const LEFT := "kb_left"
const RIGHT := "kb_right"
const CONFIRM := "kb_confirm"
const PAUSE := "kb_pause"

## Action -> physical keys.
const ACTIONS := {
	THROTTLE: [KEY_UP, KEY_W, KEY_Z],
	NITRO: [KEY_X],
	BRAKE: [KEY_DOWN, KEY_S],
	LEFT: [KEY_LEFT, KEY_A],
	RIGHT: [KEY_RIGHT, KEY_D],
	CONFIRM: [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE],
	PAUSE: [KEY_ESCAPE, KEY_P],
}


## Adds the actions to the InputMap, replacing any with the same names. Safe to call more than once.
static func build_input_map() -> void:
	for action: String in ACTIONS:
		if InputMap.has_action(action):
			InputMap.erase_action(action)
		InputMap.add_action(action)
		for key: int in ACTIONS[action]:
			var event := InputEventKey.new()
			event.physical_keycode = key as Key
			InputMap.action_add_event(action, event)


static func has_input_map() -> bool:
	for action: String in ACTIONS:
		if not InputMap.has_action(action):
			return false
	return true


## Held controls as Held bits. X is nitro and also throttle.
static func held() -> int:
	var mask := 0
	if Input.is_action_pressed(THROTTLE):
		mask |= Held.ACCEL
	if Input.is_action_pressed(NITRO):
		mask |= Held.ACCEL | Held.NITRO
	if Input.is_action_pressed(BRAKE):
		mask |= Held.BRAKE
	if Input.is_action_pressed(LEFT):
		mask |= Held.LEFT
	if Input.is_action_pressed(RIGHT):
		mask |= Held.RIGHT
	return mask


## The presses one event makes, as PlayerInput.PAUSE and CONFIRM bits: a key going down, not a repeat.
static func presses_of(event: InputEvent) -> int:
	if not (event is InputEventKey):
		return 0
	var bits := 0
	if event.is_action_pressed(CONFIRM):
		bits |= PlayerInput.CONFIRM
	if event.is_action_pressed(PAUSE):
		bits |= PlayerInput.PAUSE
	return bits
