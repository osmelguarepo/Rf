extends "res://tests/test_case.gd"
## The one change online makes to the simulation (docs/SPEC_ONLINE.md §16.4): stepped with `rejoin`, a Match gives a seat back
## to a person handed the bot byte 0xFF when a real byte arrives again. Stepped without it (the local game) leaving stays for
## good. It is a parameter of step(), not state, so checksums and snapshots are what they were.

const Config := preload("res://scripts/sim/config.gd")
const Match := preload("res://scripts/sim/match.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")


func _bytes(first: int, second: int) -> PackedByteArray:
	return PackedByteArray([first, second, PlayerInput.BOT])


func test_the_local_game_never_gives_a_seat_back() -> void:
	var m := Match.create(Config.game(), 9, 3, 0b011)
	m.step(_bytes(PlayerInput.BOT, PlayerInput.NONE))
	assert_eq(m.abandoned_mask, 0b01)
	for i in 5:
		m.step(_bytes(PlayerInput.NONE, PlayerInput.NONE))
	assert_eq(m.abandoned_mask, 0b01, "a real byte after 0xFF does not undo it")


func test_with_rejoin_a_real_byte_gives_the_seat_back() -> void:
	var m := Match.create(Config.game(), 9, 3, 0b011)
	m.step(_bytes(PlayerInput.BOT, PlayerInput.BOT), true)
	assert_eq(m.abandoned_mask, 0b11)
	m.step(_bytes(PlayerInput.NONE, PlayerInput.BOT), true)
	assert_eq(m.abandoned_mask, 0b10, "seat 0 is back, seat 1 still away")
	m.step(_bytes(PlayerInput.NONE, PlayerInput.BOT), true)
	assert_eq(m.abandoned_mask, 0b10)


func test_a_seat_that_keeps_getting_ff_stays_abandoned_with_rejoin() -> void:
	var m := Match.create(Config.game(), 9, 3, 0b011)
	for i in 30:
		m.step(_bytes(PlayerInput.BOT, PlayerInput.NONE), true)
	assert_eq(m.abandoned_mask, 0b01)
	assert_eq(m.ranking_order().back(), 0, "the one who left ranks last")


func test_a_person_who_comes_back_ranks_where_they_finish() -> void:
	var m := Match.create(Config.game(), 9, 3, 0b011)
	m.step(_bytes(PlayerInput.BOT, PlayerInput.NONE), true)
	assert_eq(m.ranking_order().back(), 0)
	m.step(_bytes(PlayerInput.NONE, PlayerInput.NONE), true)
	assert_eq(m.abandoned_mask, 0)
	assert_eq(m.ranking_order().size(), 3)


func test_rejoin_does_not_change_the_simulation() -> void:
	var a := Match.create(Config.game(), 4, 3, 0b011)
	var b := Match.create(Config.game(), 4, 3, 0b011)
	for i in 120:
		var bytes := _bytes(PlayerInput.encode(true, false, i % 3 - 1, i % 5 == 0), PlayerInput.NONE)
		a.step(bytes)
		b.step(bytes, true)
	assert_eq(a.checksum(), b.checksum(), "when nobody left, both rules play the same match")
