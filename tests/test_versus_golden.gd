extends "res://tests/test_case.gd"
## Plan §8 B1: 6 seats for 7200 ticks give the same checksum on two runs, equal to tests/golden/versus_checksum.txt.
##
## The scenario (run_scenario(), also used by tools/versus_golden.gd, which rewrites the file):
## - Through Match: Match.create(Config.standard(), SEED (20261017), 6 seats, HUMANS (0b000101: seats 0 and 2 human,
##   seats 1, 3, 4 and 5 bots)), for TICKS (7200) steps.
## - Every seat's byte is 0xFF on every step, so bot.gd drives every car, human seats included (as after a
##   disconnect), with two exceptions on seat 0: a pause press (PAUSE, steer none) on steps PAUSE_STEPS (1800 and
##   1860: pause, then resume), and a confirm press (CONFIRM, steer none) on every step that begins with the match in
##   ROUND_OVER, so the next round starts Config.MATCH_CONFIRM_TICKS steps after a round ends.
## - The checksum is Match.checksum() after the last step: the whole match, its world, the seats, the traffic and the
##   bots, bit for bit.
## The run plays a whole round, with bots going out on the way, and part of the next one.
##
## The file holds the 64 hex digits and a newline. It changes whenever the rules, the bots, the traffic or the state's
## layout change: after such a change, on purpose, regenerate it with
##   godot --headless --path . -s res://tools/versus_golden.gd
## and say why in the commit.

const Config := preload("res://scripts/sim/config.gd")
const World := preload("res://scripts/sim/world.gd")
const Match := preload("res://scripts/sim/match.gd")
const Car := preload("res://scripts/sim/car.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")

const GOLDEN_PATH := "res://tests/golden/versus_checksum.txt"
const SEED := 20261017
const SEATS := 6
const HUMANS := 0b000101
const TICKS := 7200
const PAUSE_STEPS: Array[int] = [1800, 1860]


func test_six_seats_7200_ticks_match_the_golden_checksum() -> void:
	var first := run_scenario()
	var second := run_scenario()
	assert_eq(second, first, "two runs of the scenario")
	var golden := FileAccess.get_file_as_string(GOLDEN_PATH).strip_edges()
	assert_eq(golden.length(), 64, "tests/golden/versus_checksum.txt holds a SHA-256")
	assert_eq(first["checksum"], golden, "the checksum of tests/golden/versus_checksum.txt")
	# What the scenario covers, so that it cannot shrink unnoticed.
	assert_gt(first["rounds"], 0, "a round ended")
	assert_eq(first["round_number"], first["rounds"] + 1, "and the next one started")
	assert_eq(first["paused_steps"], PAUSE_STEPS[1] - PAUSE_STEPS[0], "the pause")
	assert_gt(first["bots_out"], 0, "bots went out while their round went on")
	assert_gt(first["pickups"], 0, "fuel cars were taken")


## Plays the scenario once: {checksum, rounds, round_number, paused_steps, bots_out, pickups, winners}.
static func run_scenario() -> Dictionary:
	var m := Match.create(Config.standard(), SEED, SEATS, HUMANS)
	var bytes := PackedByteArray()
	bytes.resize(SEATS)
	var paused := 0
	var bots_out := 0
	var pickups := 0
	for step in TICKS:
		bytes.fill(PlayerInput.BOT)
		if PAUSE_STEPS.has(step):
			bytes[0] = PlayerInput.PAUSE | PlayerInput.STEER_NONE
		elif m.phase == Match.ROUND_OVER:
			bytes[0] = PlayerInput.CONFIRM | PlayerInput.STEER_NONE
		m.step(bytes)
		if m.world.phase == World.PAUSED:
			paused += 1
		for p: Car in m.world.players:
			if (p.events & World.EV_OUT) != 0 and p.human == 0 and m.world.phase == World.RUNNING:
				bots_out += 1
			if (p.events & World.EV_PICKUP) != 0:
				pickups += 1
	return {
		"checksum": m.checksum(), "rounds": m.rounds_played(), "round_number": m.round_number,
		"paused_steps": paused, "bots_out": bots_out, "pickups": pickups, "winners": m.round_winners.duplicate(),
	}
