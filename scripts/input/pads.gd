extends RefCounted
## Joypads, read one device at a time (docs/GODOT_PLAN.md §5; the gamepad half of src/input.ts in the Phaser
## version). Held controls are polled per device with Input.is_joy_button_pressed() and Input.get_joy_axis();
## presses come from InputEventJoypadButton events, which carry their device. Nothing goes through InputMap actions,
## which would merge every device into one. Phase B (seats.gd, B2) reads each device for its own seat; single
## player merges them all (held_any()).
##
## Mapping (Godot's SDL layout, which is the standard Gamepad layout the Phaser version used):
##
##   D-pad or left stick   steer, up = throttle, down = brake (stick threshold 0.5)
##   A (bottom)            nitro and throttle (held); confirm (press)
##   B (right)             throttle (held)
##   Start                 pause and confirm (press)

const Held := preload("res://scripts/input/held.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")

## Stick deflection beyond which it counts as a direction (PAD_STICK_THRESHOLD in Phaser).
const STICK_THRESHOLD := 0.5

## Devices to poll: connected when this was made, connected later (connection_changed()), or seen in an event.
## Input.get_connected_joypads() is empty without a display (plan §5), hence the events.
var devices: Array[int] = []


func _init() -> void:
	for device: int in Input.get_connected_joypads():
		note(device)


func note(device: int) -> void:
	if device >= 0 and not devices.has(device):
		devices.append(device)
		devices.sort()


## Follows Input.joy_connection_changed: a disconnected device is no longer polled.
func connection_changed(device: int, connected: bool) -> void:
	if connected:
		note(device)
	else:
		devices.erase(device)


## The presses one event makes, as PlayerInput.PAUSE and CONFIRM bits: A confirms; Start pauses and confirms. Any
## joypad event also makes its device known.
func presses_of(event: InputEvent) -> int:
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		note(event.device)
	return press_bits(event)


## The same as presses_of() without noting the device.
static func press_bits(event: InputEvent) -> int:
	var button := event as InputEventJoypadButton
	if button == null or not button.pressed:
		return 0
	if button.button_index == JOY_BUTTON_A:
		return PlayerInput.CONFIRM
	if button.button_index == JOY_BUTTON_START:
		return PlayerInput.PAUSE | PlayerInput.CONFIRM
	return 0


## Held controls of one device, as Held bits.
static func held_of(device: int) -> int:
	var x := Input.get_joy_axis(device, JOY_AXIS_LEFT_X)
	var y := Input.get_joy_axis(device, JOY_AXIS_LEFT_Y)
	var a := Input.is_joy_button_pressed(device, JOY_BUTTON_A)
	var b := Input.is_joy_button_pressed(device, JOY_BUTTON_B)
	var up := Input.is_joy_button_pressed(device, JOY_BUTTON_DPAD_UP) or y < -STICK_THRESHOLD
	var down := Input.is_joy_button_pressed(device, JOY_BUTTON_DPAD_DOWN) or y > STICK_THRESHOLD
	var left := Input.is_joy_button_pressed(device, JOY_BUTTON_DPAD_LEFT) or x < -STICK_THRESHOLD
	var right := Input.is_joy_button_pressed(device, JOY_BUTTON_DPAD_RIGHT) or x > STICK_THRESHOLD
	var mask := 0
	if up or a or b:
		mask |= Held.ACCEL
	if a:
		mask |= Held.NITRO
	if down:
		mask |= Held.BRAKE
	if left:
		mask |= Held.LEFT
	if right:
		mask |= Held.RIGHT
	return mask


## Held controls of every known device together.
func held_any() -> int:
	var mask := 0
	for device: int in devices:
		mask |= held_of(device)
	return mask
