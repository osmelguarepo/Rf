extends RefCounted
## Seeded RNG: mulberry32, bit for bit the same as src/game/rng.ts in the Phaser version (commit 0a0841f).
## tests/test_golden.gd checks it against the TypeScript outputs in tests/golden/phaser_golden.json (10 seeds, and
## 1 000 000 outputs); tests/test_rng.gd checks the helpers and clone().
##
## The state is one u32 kept in an int. All arithmetic stays in [0, 2^32), so no right shift sees a negative number.

const Self := preload("res://scripts/sim/rng.gd")

const TWO_POW_32 := 4294967296.0

var state: int = 0


func _init(p_seed: int = 0) -> void:
	state = p_seed & 0xFFFFFFFF


## Math.imul for operands in [0, 2^32): the low 32 bits of a x b, without overflowing 64-bit ints.
static func _imul(a: int, b: int) -> int:
	return (a * (b & 0xFFFF) + (((a * (b >> 16)) & 0xFFFF) << 16)) & 0xFFFFFFFF


## Next output as the u32 behind next(): next() == next_u32() / 2^32.
func next_u32() -> int:
	state = (state + 0x6D2B79F5) & 0xFFFFFFFF
	var t := _imul(state ^ (state >> 15), state | 1)
	t ^= (t + _imul(t ^ (t >> 7), t | 61)) & 0xFFFFFFFF
	return (t ^ (t >> 14)) & 0xFFFFFFFF


## Uniform float in [0, 1).
func next() -> float:
	return float(next_u32()) / TWO_POW_32


## Uniform float in [lo, hi). Phaser's rng.range(min, max).
func float_range(lo: float, hi: float) -> float:
	return lo + (hi - lo) * next()


## Uniform integer in [lo, hi], both included. Phaser's rng.int(min, max).
func int_range(lo: int, hi: int) -> int:
	return lo + floori(next() * float(hi - lo + 1))


## Index of a uniform pick among `count` items. Phaser's rng.pick(items) is items[pick_index(items.length)].
func pick_index(count: int) -> int:
	return floori(next() * float(count))


func clone() -> Self:
	var r := Self.new()
	r.state = state
	return r
