extends "res://tests/test_case.gd"
## scripts/sim/rng.gd beyond the golden outputs (tests/test_golden.gd): the helpers' formulas, the u32 state and
## clone().

const Rng := preload("res://scripts/sim/rng.gd")


## Plan §3: int(lo, hi) = lo + floori(next() * (hi - lo + 1)); range and pick follow Phaser's rng.ts.
func test_helpers_follow_the_plans_formulas() -> void:
	var a := Rng.new(424242)
	var b := Rng.new(424242)
	for i in 100:
		assert_eq(a.int_range(-3, 9), -3 + floori(b.next() * 13.0))
		assert_eq(a.float_range(2.5, 7.0), 2.5 + 4.5 * b.next())
		assert_eq(a.pick_index(6), floori(b.next() * 6.0))


func test_outputs_stay_in_range() -> void:
	var rng := Rng.new(1)
	var low := 1.0
	var high := 0.0
	var ints := {}
	for i in 5000:
		var x := rng.next()
		low = minf(low, x)
		high = maxf(high, x)
		ints[rng.int_range(5, 6)] = true
	assert_between(low, 0.0, 0.01)
	assert_between(high, 0.99, 1.0)
	assert_lt(high, 1.0, "next() is in [0, 1)")
	assert_eq(ints.keys().size(), 2, "int(5, 6) gives both ends")


## The state is one u32: seeds outside [0, 2^32) are masked as JavaScript's `seed >>> 0` does.
func test_state_is_a_u32() -> void:
	assert_eq(Rng.new(-1).state, 0xFFFFFFFF)
	assert_eq(Rng.new(0x1_0000_0005).state, 5)
	var rng := Rng.new(0xFFFFFFFF)
	var outside := 0
	for i in 1000:
		rng.next_u32()
		if rng.state < 0 or rng.state > 0xFFFFFFFF:
			outside += 1
	assert_eq(outside, 0)


func test_clone_continues_the_same_sequence() -> void:
	var rng := Rng.new(99)
	for i in 10:
		rng.next()
	var copy := rng.clone()
	var a: Array[int] = []
	var b: Array[int] = []
	for i in 20:
		a.append(rng.next_u32())
		b.append(copy.next_u32())
	assert_eq(a, b)
