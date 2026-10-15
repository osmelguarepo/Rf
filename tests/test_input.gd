extends "res://tests/test_case.gd"
## The input byte (scripts/sim/player_input.gd, docs/GODOT_PLAN.md §3) and the edge latch, which replaces the
## Phaser src/game/edges.ts (the two latchEdges tests of tests/loop.test.ts).

const PlayerInput := preload("res://scripts/sim/player_input.gd")


## bit 0 accelerate, bit 1 brake, bits 2-3 steer + 1, bit 4 high gear, bit 5 pause, bit 6 confirm, 0xFF bot.
func test_byte_layout_is_the_plans() -> void:
	assert_eq(PlayerInput.ACCEL, 1)
	assert_eq(PlayerInput.BRAKE, 2)
	assert_eq(PlayerInput.STEER_SHIFT, 2)
	assert_eq([PlayerInput.STEER_LEFT, PlayerInput.STEER_NONE, PlayerInput.STEER_RIGHT], [0, 4, 8])
	assert_eq(PlayerInput.HIGH_GEAR, 16)
	assert_eq(PlayerInput.PAUSE, 32)
	assert_eq(PlayerInput.CONFIRM, 64)
	assert_eq(PlayerInput.BOT, 0xFF)
	assert_eq(PlayerInput.NONE, 4, "no input: steer bits at none")
	assert_eq(PlayerInput.encode(true, false, -1, false), 1, "accelerate, steer left")
	assert_eq(PlayerInput.encode(false, false, 0, false), 4)
	assert_eq(PlayerInput.encode(false, true, 1, true, true, true), 2 | 8 | 16 | 32 | 64)


func test_encode_and_read_back_every_combination() -> void:
	var wrong := 0
	for bits in 32:
		var accel := (bits & 1) != 0
		var brake := (bits & 2) != 0
		var high := (bits & 4) != 0
		var pause := (bits & 8) != 0
		var confirm := (bits & 16) != 0
		for steer: int in [-1, 0, 1]:
			var byte := PlayerInput.encode(accel, brake, steer, high, pause, confirm)
			var back := [
				PlayerInput.accel(byte), PlayerInput.brake(byte), PlayerInput.steer_of(byte),
				PlayerInput.high_gear(byte), PlayerInput.pause(byte), PlayerInput.confirm(byte), byte < 128,
			]
			if not strict_equal(back, [accel, brake, steer, high, pause, confirm, true]):
				wrong += 1
	assert_eq(wrong, 0, "combinations that do not read back")


func test_steer_bits_3_read_as_no_steering() -> void:
	assert_eq(PlayerInput.steer_of(PlayerInput.STEER_MASK), 0)
	assert_eq(PlayerInput.steer_of(0), -1, "a zero byte steers left")


func test_the_bot_byte_never_pauses_or_confirms() -> void:
	assert_true(PlayerInput.is_bot(PlayerInput.BOT))
	assert_false(PlayerInput.pause(PlayerInput.BOT))
	assert_false(PlayerInput.confirm(PlayerInput.BOT))
	assert_false(PlayerInput.is_bot(0x7F))


## Phaser loop.test.ts: "keeps a press that has not been consumed yet".
func test_latch_keeps_a_press_until_a_step_consumes_it() -> void:
	var pending := PlayerInput.latch(0, PlayerInput.CONFIRM)
	var next := PlayerInput.latch(pending, 0)
	assert_true(PlayerInput.confirm(next))


## Phaser loop.test.ts: "combines simultaneous presses of different actions".
func test_latch_combines_presses_of_different_actions() -> void:
	var out := PlayerInput.latch(PlayerInput.CONFIRM, PlayerInput.PAUSE)
	assert_eq(out, PlayerInput.CONFIRM | PlayerInput.PAUSE)
	assert_eq(PlayerInput.latch(PlayerInput.ACCEL | PlayerInput.STEER_RIGHT, 0), 0, "held bits are not latched")


func test_with_edges_merges_held_bits_and_latched_presses() -> void:
	var held := PlayerInput.ACCEL | PlayerInput.HIGH_GEAR | PlayerInput.STEER_RIGHT | PlayerInput.PAUSE
	var byte := PlayerInput.with_edges(held, PlayerInput.CONFIRM)
	assert_eq(byte, PlayerInput.ACCEL | PlayerInput.HIGH_GEAR | PlayerInput.STEER_RIGHT | PlayerInput.CONFIRM)
	assert_false(PlayerInput.is_bot(PlayerInput.with_edges(0xFF, 0)), "never produces the bot byte")
