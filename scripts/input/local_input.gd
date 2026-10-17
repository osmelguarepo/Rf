extends RefCounted
## The single-player input: the keyboard and every joypad together, as one input byte per simulation step
## (docs/GODOT_PLAN.md §3, §5; src/input.ts and src/game/edges.ts in the Phaser version).
##
## - Held controls (throttle, brake, steer, high gear) are read when a step asks for its byte.
## - Presses (pause, confirm) are latched when their event arrives and kept until a step (step_byte()) or a menu
##   (take_presses()) takes them, so a press on a frame with no fixed step is not lost.
##
## app.gd forwards every input event to handle_event(), and Input.joy_connection_changed to connection_changed().
## Phase B swaps this object for seats.gd (B2), which hands out one byte per seat with the same calls: handle_event(),
## connection_changed(), step_bytes(), take_presses(), press() and clear_presses(). App.input is typed with this
## script, so seats.gd extends it.

const PlayerInput := preload("res://scripts/sim/player_input.gd")
const Held := preload("res://scripts/input/held.gd")
const Keyboard := preload("res://scripts/input/keyboard.gd")
const Pads := preload("res://scripts/input/pads.gd")

var pads := Pads.new()
## Latched presses (PlayerInput.PAUSE and CONFIRM bits) that nothing has taken yet.
var pending: int = 0


func _init() -> void:
	if not Keyboard.has_input_map():
		Keyboard.build_input_map()


## Latches the presses an event makes. Returns true if it made any.
func handle_event(event: InputEvent) -> bool:
	var bits := Keyboard.presses_of(event) | pads.presses_of(event)
	pending = PlayerInput.latch(pending, bits)
	return bits != 0


## A joypad connected or disconnected (Input.joy_connection_changed, forwarded by the app).
func connection_changed(device: int, connected: bool) -> void:
	pads.connection_changed(device, connected)


## Held controls of the keyboard and every pad, as Held bits.
func held() -> int:
	return Keyboard.held() | pads.held_any()


## The byte for one step: held controls plus the latched presses, which it takes.
func step_byte() -> int:
	var byte := Held.to_byte(held(), pending)
	pending = 0
	return byte


## The bytes for one step of a world with `seats` seats: this player drives seat 0; any other seat gets no input.
func step_bytes(seats: int = 1) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(maxi(seats, 1))
	bytes.fill(PlayerInput.NONE)
	bytes[0] = step_byte()
	return bytes


## Takes the latched presses without stepping (menus, the game-over screen).
func take_presses() -> int:
	var presses := pending
	pending = 0
	return presses


## Latches a press made by the program, such as the pause when the window loses focus.
func press(bits: int) -> void:
	pending = PlayerInput.latch(pending, bits)


func clear_presses() -> void:
	pending = 0
