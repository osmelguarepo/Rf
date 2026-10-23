extends RefCounted
## The input byte: what the simulation reads from one seat for one step (docs/GODOT_PLAN.md §3).
## World.step() takes a PackedByteArray with one of these per seat.
##
##   bit 0     accelerate (held)
##   bit 1     brake (held, beats the throttle)
##   bits 2-3  steer + 1: 0 left, 1 none, 2 right (3 reads as none)
##   bit 4     nitro (held)
##   bit 5     pause (press: set only on the step that consumes the press)
##   bit 6     confirm (press)
##   bit 7     never set by a person
##   0xFF      BOT: a bot drives this seat. bot.gd (phase B) chooses its byte inside World.step().
##
## A zero byte means "steer left". "No input" is NONE (steer bits = 1).

const ACCEL := 1
const BRAKE := 2
const STEER_SHIFT := 2
const STEER_MASK := 12
const STEER_LEFT := 0
const STEER_NONE := 4
const STEER_RIGHT := 8
const NITRO := 16
const PAUSE := 32
const CONFIRM := 64
## The one-shot bits. Everything else is held.
const EDGES := 96
const NONE := 4
const BOT := 255


static func encode(
	p_accel: bool, p_brake: bool, p_steer: int, p_nitro: bool, p_pause: bool = false, p_confirm: bool = false
) -> int:
	var byte := 0
	if p_accel:
		byte |= ACCEL
	if p_brake:
		byte |= BRAKE
	byte |= (clampi(p_steer, -1, 1) + 1) << STEER_SHIFT
	if p_nitro:
		byte |= NITRO
	if p_pause:
		byte |= PAUSE
	if p_confirm:
		byte |= CONFIRM
	return byte


## -1 left, 0 none, 1 right.
static func steer_of(byte: int) -> int:
	var bits := (byte & STEER_MASK) >> STEER_SHIFT
	if bits == 0:
		return -1
	if bits == 2:
		return 1
	return 0


static func is_bot(byte: int) -> bool:
	return byte == BOT


static func accel(byte: int) -> bool:
	return (byte & ACCEL) != 0


static func brake(byte: int) -> bool:
	return (byte & BRAKE) != 0


static func nitro(byte: int) -> bool:
	return (byte & NITRO) != 0


static func pause(byte: int) -> bool:
	return byte != BOT and (byte & PAUSE) != 0


static func confirm(byte: int) -> bool:
	return byte != BOT and (byte & CONFIRM) != 0


## Keeps one-shot presses until a step consumes them, so a press that lands on a frame with no fixed step is not
## lost (src/game/edges.ts latchEdges). `pending` and `pressed` are bytes; only their EDGES bits matter.
static func latch(pending: int, pressed: int) -> int:
	return (pending | pressed) & EDGES


## The byte for one step: the held bits of `held` plus the latched presses in `edges`.
static func with_edges(held: int, edges: int) -> int:
	return (held & ~EDGES & 0x7F) | (edges & EDGES)
