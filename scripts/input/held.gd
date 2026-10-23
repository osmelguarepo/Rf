extends RefCounted
## Held controls of one device, as bits, and the input byte they make (docs/GODOT_PLAN.md §3).
##
## Devices report what is held as these bits, not as input bytes, because bytes cannot be merged: the byte's steer
## field (bits 2-3) holds left, none or right, and OR-ing "left" with "none" would read as "none". to_byte() decides
## the steer from the merged LEFT and RIGHT bits, as the Phaser version did: both or neither held is no steering.

const PlayerInput := preload("res://scripts/sim/player_input.gd")

const ACCEL := 1
const BRAKE := 2
const LEFT := 4
const RIGHT := 8
const NITRO := 16


static func steer_of(mask: int) -> int:
	var left := (mask & LEFT) != 0
	var right := (mask & RIGHT) != 0
	if left == right:
		return 0
	return 1 if right else -1


## The input byte for one step: the held bits of `mask` plus the latched presses (PAUSE, CONFIRM) of `presses`.
static func to_byte(mask: int, presses: int = 0) -> int:
	var held := PlayerInput.encode((mask & ACCEL) != 0, (mask & BRAKE) != 0, steer_of(mask), (mask & NITRO) != 0)
	return PlayerInput.with_edges(held, presses)
