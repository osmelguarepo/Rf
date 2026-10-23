extends "res://tests/test_case.gd"
## The match (scripts/sim/match.gd; docs/GODOT_PLAN.md §7 "Partida"): best of three rounds of one versus World, the
## cap of five rounds, a single human's two wins or two losses, rounds nobody wins, the round reset with an RNG that
## goes on, the confirm press between rounds, a disconnect in mid-match, and the match's state.
##
## Most tests play quiet rounds: the spawner is stopped and the cars stand, and _end_round() ends a round in one step
## with the scores given and the seats given running dry, so the World's own rules pick the round's winner.

const Config := preload("res://scripts/sim/config.gd")
const Rng := preload("res://scripts/sim/rng.gd")
const Car := preload("res://scripts/sim/car.gd")
const Traffic := preload("res://scripts/sim/traffic.gd")
const World := preload("res://scripts/sim/world.gd")
const Bot := preload("res://scripts/sim/bot.gd")
const Match := preload("res://scripts/sim/match.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")
const H := preload("res://tests/sim_helpers.gd")

const BOT := PlayerInput.BOT
const NO_WINNER := Match.NO_WINNER
## Match fields that to_array() writes as arrays rather than as SCALARS.
const COMPOSITE_FIELDS := ["world", "wins", "totals", "distances", "round_winners", "race_points", "race_order"]

var std := Config.standard()


## Plan §7: the first to 2 round wins takes the match; 1-1 decides nothing. With three or more humans the wins can be
## shared (1-1-1): after 5 rounds the most wins decide, then the most points over the match, then the most distance;
## level on all three, nobody wins the match. Only the human seats are ranked: a bot never wins the match.
func test_first_to_two_and_cap_five() -> void:
	# Two humans and a bot: 1-1, then seat 0's second win.
	var m := _match(3, 0b011)
	_end_round(m, [500, 100, 9999], [1])
	assert_eq([m.phase, m.last_round_winner(), m.wins], [Match.ROUND_OVER, 0, [1, 0, 0]], "seat 0 won; the bot's points do not count")
	assert_eq(m.events, Match.EV_ROUND_OVER)
	_next(m)
	_end_round(m, [100, 500, 0], [0])
	assert_eq([m.phase, m.wins], [Match.ROUND_OVER, [1, 1, 0]], "1-1 decides nothing")
	_next(m)
	_end_round(m, [500, 100, 0], [1])
	assert_eq([m.phase, m.winner, m.wins, m.rounds_played(), m.round_number], [Match.MATCH_OVER, 0, [2, 1, 0], 3, 3])
	assert_eq(m.events, Match.EV_ROUND_OVER | Match.EV_MATCH_OVER)

	# The first to two, in two rounds.
	var quick := _match(3, 0b011)
	_end_round(quick, [100, 500, 0], [0])
	_next(quick)
	_end_round(quick, [100, 500, 0], [0])
	assert_eq([quick.phase, quick.winner, quick.rounds_played()], [Match.MATCH_OVER, 1, 2])

	# Three humans, 1-1-1, then two rounds nobody wins: after five rounds, the most points over the match.
	var shared := _match(4, 0b0111)
	_end_round(shared, [500, 100, 400, 0], [1])
	_next(shared)
	_end_round(shared, [100, 500, 400, 0], [0])
	_next(shared)
	_end_round(shared, [100, 100, 500, 0], [0])
	assert_eq([shared.phase, shared.wins], [Match.ROUND_OVER, [1, 1, 1, 0]], "1-1-1 after three rounds")
	_next(shared)
	_end_round(shared, [300, 300, 100, 0], [0, 1, 2])
	assert_eq([shared.phase, shared.last_round_winner()], [Match.ROUND_OVER, NO_WINNER], "round 4: nobody")
	_next(shared)
	_end_round(shared, [700, 100, 700, 0], [0, 1, 2])
	assert_eq(shared.round_winners, [0, 1, 2, NO_WINNER, NO_WINNER] as Array[int])
	assert_eq(shared.totals, [1700, 1100, 2100, 0] as Array[int])
	assert_eq([shared.phase, shared.winner, shared.rounds_played()], [Match.MATCH_OVER, 2, 5], "five rounds: the most points")
	assert_eq(Config.MATCH_ROUNDS_MAX, 5)

	# More wins beat more points: seat 1's single win against seat 0's points in four rounds nobody won.
	var wins_first := _match(4, 0b0111)
	_end_round(wins_first, [100, 500, 400, 0], [0])
	for i in 4:
		_next(wins_first)
		_end_round(wins_first, [800, 100, 800, 0], [0, 1, 2])
	assert_eq([wins_first.phase, wins_first.winner, wins_first.wins], [Match.MATCH_OVER, 1, [0, 1, 0, 0]])
	assert_gt(wins_first.totals[0], wins_first.totals[1], "seat 0 had more points")

	# Two humans at 1-1 after five rounds, level on points: the distance over the match, then nobody.
	for distance_1: float in [50.0, 0.0]:
		var level := _match(3, 0b011)
		_end_round(level, [500, 100, 0], [1])
		_next(level)
		_end_round(level, [100, 500, 0], [0], [0.0, distance_1, 0.0])
		for i in 3:
			_next(level)
			_end_round(level, [300, 300, 0], [0, 1])
		assert_eq([level.phase, level.wins, level.totals], [Match.MATCH_OVER, [1, 1, 0], [1500, 1500, 0]])
		assert_eq(level.winner, 1 if distance_1 > 0.0 else NO_WINNER, "distance %s" % distance_1)

	# The cap ranks the human seats only. Two, then three humans level on points, distance and fuel, going out together
	# in each of five rounds, so nobody wins a round; the bot, in the last seat, scores far more and drives further
	# each round. Nobody wins the match, and never the bot, though it leads on points and distance over the match.
	for humans: int in [0b011, 0b0111]:
		var seats := 3 if humans == 0b011 else 4
		var bot_seat := seats - 1
		var capped := _match(seats, humans)
		var scores: Array = []
		var distances: Array = []
		var dry: Array = []
		for seat in seats:
			scores.append(9000 if seat == bot_seat else 300)
			distances.append(4000.0 if seat == bot_seat else 250.0)
			if seat != bot_seat:
				dry.append(seat)
		for i in Config.MATCH_ROUNDS_MAX:
			if i > 0:
				_next(capped)
			_end_round(capped, scores, dry, distances)
			assert_eq(capped.last_round_winner(), NO_WINNER, "%d humans, round %d: level" % [seats - 1, i + 1])
		assert_eq([capped.phase, capped.rounds_played(), capped.winner], [Match.MATCH_OVER, 5, NO_WINNER],
			"%d humans: five rounds, nobody wins the match" % (seats - 1))
		assert_ne(capped.winner, bot_seat, "%d humans: not the bot" % (seats - 1))
		assert_eq([capped.totals[bot_seat], capped.totals[0], capped.distances[bot_seat], capped.distances[0]],
			[45000, 1500, 20000.0, 1250.0], "%d humans: the bot leads on points and distance" % (seats - 1))


## Plan §7: each round starts afresh (World.start_round()): every seat back in its start lane on the anchor line,
## alive (bots out in the round before come back), stopped, a full tank, no points or distance; an empty road; the gaps
## and the difficulty clock from the start; every bot afresh. Kept: the world RNG (three draws on, for the new spawner),
## the seats' and the bots' streams, the human flags, the tick and the seed; and the match's wins and points.
func test_round_reset() -> void:
	var m := Match.create(std, 11, 4, 0b0001)
	var w := m.world
	var bytes: Array = [BOT, BOT, BOT, BOT]
	H.run_bytes(w, bytes, 1300)
	assert_eq([w.phase, w.gap_scale], [World.RUNNING, 0.9], "a round 21 s in, the gaps shrunk once")
	w.players[2].fuel = 0.001
	_step_match(m, bytes)
	assert_eq([w.players[2].alive, w.phase], [0, World.RUNNING], "bot 2 out, the round goes on")
	assert_gt(w.traffic.size(), 0)
	w.players[0].fuel = 0.001
	_step_match(m, bytes)
	assert_eq(m.phase, Match.ROUND_OVER)
	var scores: Array[int] = []
	for p: Car in w.players:
		scores.append(p.score)
	var world_rng := w.rng.state
	var seat_streams: Array = []
	var bot_streams: Array = []
	for i in w.players.size():
		seat_streams.append(w.players[i].rng.state)
		bot_streams.append(w.bots[i].rng.state)
	var tick := w.tick
	_next(m, false)
	assert_eq([m.phase, m.round_number, m.totals], [Match.PLAYING, 2, scores], "the match goes on with round 2")
	assert_eq(m.events, Match.EV_ROUND_START)
	var problems: Array = []
	var lanes: Array = Config.VERSUS_START_LANES[4]
	for p: Car in w.players:
		var fresh := [p.x, w.screen_y(p.y_world), p.speed, p.gear, p.fuel, p.score, p.alive, p.distance, p.touching_edge,
			p.slide_vx, p.invulnerable, p.events]
		var expected := [Traffic.lane_x(std, lanes[p.slot], p.w), 192.0, 0.0, Car.GEAR_LOW, 100.0, 0, 1, 0.0, 0, 0.0, 0, 0]
		if not strict_equal(fresh, expected):
			problems.append("seat %d: %s" % [p.slot, fresh])
		var b := w.bots[p.slot]
		if not strict_equal([b.pending.size(), b.lane, b.last_tick], [Config.BOT_REACTION_TICKS, -1, -1]) or b.pending.count(Bot.START_BYTE) != b.pending.size():
			problems.append("bot %d not afresh" % p.slot)
	assert_eq(problems, [], "every seat and bot afresh")
	assert_eq([w.traffic.size(), w.gap_scale, w.stage_ticks, w.camera_y, w.phase, w.winner, w.events],
		[0, 1.0, 0, 0.0, World.RUNNING, NO_WINNER, 0], "the road, the gaps, the clocks")
	var replica := Rng.new(world_rng)
	for i in 3:
		replica.next()
	assert_eq(w.rng.state, replica.state, "the world RNG went on: three draws for the new spawner")
	var streams_now: Array = []
	var bots_now: Array = []
	for i in w.players.size():
		streams_now.append(w.players[i].rng.state)
		bots_now.append(w.bots[i].rng.state)
	assert_eq([streams_now, bots_now], [seat_streams, bot_streams], "the seats' and the bots' streams went on")
	var humans: Array = []
	for p: Car in w.players:
		humans.append(p.human)
	assert_eq([humans, w.tick, w.game_seed], [[1, 0, 0, 0], tick + Config.MATCH_CONFIRM_TICKS, 11], "kept")


## Plan §7: with a single human the match ends at the human's 2 wins (the human wins it) or at 2 rounds the human did
## not win (nobody wins it: bots never win). The human wins a round by beating every bot still in it, or when every
## bot is out.
func test_single_human_two_wins_or_two_losses() -> void:
	var cases := [
		[["win", "win"], 0], [["loss", "loss"], NO_WINNER], [["win", "loss", "win"], 0],
		[["loss", "win", "loss"], NO_WINNER], [["win", "loss", "loss"], NO_WINNER], [["loss", "bots_out", "win"], 0],
	]
	for case: Array in cases:
		var m := _match(3, 0b001)
		var outcomes: Array = case[0]
		for i in outcomes.size():
			if i > 0:
				_next(m)
			match outcomes[i]:
				"win":
					_end_round(m, [500, 100, 100], [0])
				"loss":
					_end_round(m, [100, 500, 100], [0])
				"bots_out":
					_end_round(m, [0, 900, 900], [1, 2])
			var expected := NO_WINNER if outcomes[i] == "loss" else 0
			assert_eq(m.last_round_winner(), expected, "%s, round %d" % [outcomes, i + 1])
			var last := i == outcomes.size() - 1
			assert_eq(m.phase, Match.MATCH_OVER if last else Match.ROUND_OVER, "%s, round %d" % [outcomes, i + 1])
		assert_eq(m.winner, case[1], "%s" % [outcomes])
		assert_eq(m.wins[0] + m.losses(0), outcomes.size())
		assert_true(m.wins[0] == Config.MATCH_WINS or m.losses(0) == Config.MATCH_LONE_LOSSES)
		assert_eq([m.wins[1], m.wins[2]], [0, 0], "bots never win")


## A round nobody wins (World.winner NO_WINNER) counts for nobody: no win for anyone, one round more played (its
## points still count in the totals). Two humans can then need more than three rounds.
func test_rounds_without_a_winner_count_for_nobody() -> void:
	var m := _match(3, 0b011)
	_end_round(m, [300, 300, 0], [0, 1])
	assert_eq([m.phase, m.last_round_winner(), m.wins, m.rounds_played(), m.totals],
		[Match.ROUND_OVER, NO_WINNER, [0, 0, 0], 1, [300, 300, 0]])
	assert_eq([m.losses(0), m.losses(1)], [1, 1])
	_next(m)
	_end_round(m, [200, 200, 0], [0, 1])
	_next(m)
	_end_round(m, [500, 100, 0], [1])
	assert_eq([m.phase, m.wins], [Match.ROUND_OVER, [1, 0, 0]], "three rounds, one win: not over")
	_next(m)
	_end_round(m, [500, 100, 0], [1])
	assert_eq([m.phase, m.winner, m.rounds_played(), m.round_winners],
		[Match.MATCH_OVER, 0, 4, [NO_WINNER, NO_WINNER, 0, 0] as Array[int]])


## Plan §7: "El RNG continúa": the next round's traffic comes from the world RNG where the last round left it (three
## draws on, for the new spawner), not from the seed again, so every round is a new road; and a whole match still
## follows from its seed: the same seed and bytes give the same match, round after round.
func test_rng_continues_across_rounds() -> void:
	var m := Match.create(std, 21, 4, 0b0011)
	var spawns: Array = [[], []]
	var ended_at := _play_round(m, spawns[0])
	assert_gt(ended_at, 0, "round 1 ended")
	var end_state := m.world.rng.state
	_next(m, false)
	var replica := Rng.new(end_state)
	for i in 3:
		replica.next()
	assert_eq(m.world.rng.state, replica.state, "round 2 starts from where round 1 left the RNG")
	var fresh := World.versus(std, 21, 4, 0b0011)
	assert_ne(m.world.rng.state, fresh.rng.state, "not from the seed again")
	for i in 900:
		_step_match(m, [BOT, BOT, BOT, BOT])
		_log_spawns(m.world, spawns[1])
	var first: Array = spawns[0].slice(0, 20)
	var second: Array = spawns[1].slice(0, 20)
	assert_eq(second.size(), 20, "round 2 spawned traffic")
	assert_ne(second, first, "a new road")

	var again := Match.create(std, 21, 4, 0b0011)
	_play_round(again, [])
	_next(again, false)
	for i in 900:
		_step_match(again, [BOT, BOT, BOT, BOT])
	assert_eq(again.checksum(), m.checksum(), "the same seed and bytes: the same match")


## Plan §7: a human whose controller goes away mid-match keeps the seat: its bot drives it (byte 0xFF), it is still
## one of the match's humans, it can win rounds, and its going out ends a round. 0xFF never confirms between rounds,
## and neither does a bot seat; another human does. The seat's own bytes drive it again when the controller is back.
func test_disconnect_mid_match() -> void:
	var m := _match(3, 0b011)
	var w := m.world
	for i in 120:
		_step_match(m, [H.NONE, BOT, BOT])
	var away := w.players[1]
	assert_gt(away.speed, 100.0, "its bot drives the seat")
	assert_eq([away.human, m.human_seats()], [1, [0, 1] as Array[int]], "still a human seat of the match")
	_end_round(m, [100, 500, 0], [0])
	assert_eq([m.phase, m.last_round_winner()], [Match.ROUND_OVER, 1], "the bot-driven human seat won the round")
	for i in 300:
		_step_match(m, [H.NONE, BOT, H.CONFIRM])
	assert_eq(m.phase, Match.ROUND_OVER, "0xFF and a bot seat's confirm do not start the next round")
	_step_match(m, [H.CONFIRM, BOT, BOT])
	assert_eq([m.phase, m.round_number], [Match.PLAYING, 2], "the other human does")
	H.quiet(w)
	for i in 120:
		_step_match(m, [H.NONE, BOT, BOT])
	assert_gt(away.speed, 100.0, "its bot drives it from the round's start")
	var speed := away.speed
	for i in 30:
		_step_match(m, [H.NONE, H.BRAKE, BOT])
	assert_almost_eq(away.speed, speed - 30.0 * Config.BRAKE * Config.DT, 1e-6, "back: its own bytes drive it")
	away.fuel = 0.001
	_step_match(m, [H.NONE, H.NONE, BOT])
	assert_eq([m.phase, m.last_round_winner(), m.wins], [Match.ROUND_OVER, 0, [1, 1, 0]], "its going out ended round 2")


## Between rounds the match waits for a confirm press from a human seat, and counts it only from MATCH_CONFIRM_TICKS
## steps after the round ended (on a pad, A shifts gear and confirms: presses made while racing must not skip the
## results). Meanwhile the world takes no input: nothing moves but the tick.
func test_round_over_waits_for_a_human_confirm() -> void:
	var m := _match(3, 0b011)
	_end_round(m, [500, 100, 0], [1])
	var still := _without_ticks(m.world)
	for i in 600:
		_step_match(m, [H.ACCEL_HIGH, H.PAUSE, H.CONFIRM])
	assert_eq([m.phase, m.phase_ticks, m.round_number], [Match.ROUND_OVER, 600, 1], "no human confirm: it waits")
	assert_eq(_without_ticks(m.world), still, "nothing moved")

	var early := _match(3, 0b011)
	_end_round(early, [500, 100, 0], [1])
	for i in Config.MATCH_CONFIRM_TICKS - 1:
		_step_match(early, [H.CONFIRM, H.CONFIRM, BOT])
	assert_eq([early.phase, early.phase_ticks], [Match.ROUND_OVER, Config.MATCH_CONFIRM_TICKS - 1], "too early: dropped")
	_step_match(early, [H.NONE, H.CONFIRM, BOT])
	assert_eq([early.phase, early.round_number, early.events], [Match.PLAYING, 2, Match.EV_ROUND_START],
		"%d steps after the round ended: the next round" % Config.MATCH_CONFIRM_TICKS)
	assert_eq(early.phase_ticks, 0)
	assert_eq(Config.MATCH_CONFIRM_TICKS, 60)


## Once the match is decided it takes no input: confirm, pause and driving bytes change nothing but the tick.
func test_match_over_takes_no_input() -> void:
	var m := _match(2, 0b01)
	_end_round(m, [500, 100], [0])
	_next(m)
	_end_round(m, [500, 100], [0])
	assert_eq([m.phase, m.winner], [Match.MATCH_OVER, 0])
	var still := _without_ticks(m.world)
	var fields := [m.phase, m.round_number, m.winner, m.wins, m.totals, m.round_winners]
	for i in 300:
		_step_match(m, [H.CONFIRM | PlayerInput.PAUSE, BOT])
		assert_eq(m.events, 0)
	assert_eq([m.phase, m.round_number, m.winner, m.wins, m.totals, m.round_winners], fields)
	assert_eq(_without_ticks(m.world), still)


## The match's state is complete: every field is in to_array() (the world's too), each one moves the checksum, and a
## match restored mid-round, after a round has ended, runs on to the same checksum as the one that never stopped (from
## to_array(), through var_to_bytes, and from clone()).
func test_match_state_round_trips() -> void:
	var m := Match.create(std, 31, 6, 0b111111)
	var fields: Array = []
	for property: Dictionary in m.get_property_list():
		if (int(property["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE) != 0:
			fields.append(property["name"])
	var listed: Array = Match.SCALARS.duplicate()
	listed.append_array(COMPOSITE_FIELDS)
	fields.sort()
	listed.sort()
	assert_eq(fields, listed, "Match fields")
	assert_eq(m.to_array().size(), 1 + Match.SCALARS.size() + COMPOSITE_FIELDS.size())

	var steps := 0
	while m.rounds_played() == 0 and steps < 12000:
		_drive(m)
		steps += 1
	assert_eq(m.rounds_played(), 1, "a round ended")
	for i in 400:
		_drive(m)
	assert_eq(m.phase, Match.PLAYING, "round 2 under way")
	var saved := m.to_array()
	var travelled: Array = bytes_to_var(var_to_bytes(saved))
	var copy := m.clone()
	var restored := Match.from_array(std, saved)
	var unpacked := Match.from_array(std, travelled)
	assert_eq(restored.checksum(), m.checksum(), "restored at once")
	for i in 900:
		for each: Match in [m, copy, restored, unpacked]:
			_drive(each)
	assert_eq(restored.checksum(), m.checksum(), "from to_array()")
	assert_eq(unpacked.checksum(), m.checksum(), "through var_to_bytes")
	assert_eq(copy.checksum(), m.checksum(), "from clone()")

	var unchanged := 0
	for field: String in Match.SCALARS:
		var other := m.clone()
		other.set(field, int(other.get(field)) + 1)
		if other.checksum() == m.checksum():
			unchanged += 1
	for field: String in ["wins", "totals", "distances", "round_winners"]:
		var other := m.clone()
		var values: Array = other.get(field)
		values[0] += 1
		if other.checksum() == m.checksum():
			unchanged += 1
	var moved := m.clone()
	moved.world.players[3].x += 0.5
	if moved.checksum() == m.checksum():
		unchanged += 1
	assert_eq(unchanged, 0, "fields that do not change the checksum")


# --- helpers ---------------------------------------------------------------------------------------------------------


## A match whose rounds are quiet (no traffic) until a test drives them.
func _match(seats: int, humans: int, seed_value: int = 5) -> Match:
	var m := Match.create(std, seed_value, seats, humans)
	H.quiet(m.world)
	return m


## Ends the round being played in one step: every car stopped, with scores[slot] points, distances[slot] (0 by
## default) and 50 fuel; the seats in `dry` run dry in the step. The World's rules pick the winner.
func _end_round(m: Match, scores: Array, dry: Array, distances: Array = []) -> void:
	assert_eq(m.phase, Match.PLAYING, "a round is being played")
	for p: Car in m.world.players:
		p.speed = 0.0
		p.score = scores[p.slot]
		p.distance = distances[p.slot] if p.slot < distances.size() else 0.0
		p.fuel = 0.001 if dry.has(p.slot) else 50.0
	var bytes: Array = []
	for p: Car in m.world.players:
		bytes.append(H.NONE)
	_step_match(m, bytes)
	assert_true(m.phase != Match.PLAYING, "the round ended")


## From ROUND_OVER to the next round: no input until the confirm delay is over, then a confirm press from the first
## human seat. With `quiet`, the new round's spawner is stopped too.
func _next(m: Match, quiet: bool = true) -> void:
	var bytes := PackedByteArray()
	bytes.resize(m.world.players.size())
	bytes.fill(H.NONE)
	while m.phase_ticks < Config.MATCH_CONFIRM_TICKS - 1:
		m.step(bytes)
	bytes[m.human_seats()[0]] = H.CONFIRM
	m.step(bytes)
	assert_eq(m.phase, Match.PLAYING, "the next round started")
	if quiet:
		H.quiet(m.world)


static func _step_match(m: Match, seat_bytes: Array) -> void:
	m.step(PackedByteArray(seat_bytes))


## Every seat 0xFF; while the round is over, the first human seat confirms.
static func _drive(m: Match) -> void:
	var bytes := PackedByteArray()
	bytes.resize(m.world.players.size())
	bytes.fill(BOT)
	if m.phase == Match.ROUND_OVER:
		bytes[m.human_seats()[0]] = H.CONFIRM
	m.step(bytes)


## Plays the round under way with every seat 0xFF until it ends (at most 12 000 steps), logging its spawns. Returns
## the step it ended on, or -1.
func _play_round(m: Match, spawns: Array) -> int:
	var bytes := PackedByteArray()
	bytes.resize(m.world.players.size())
	bytes.fill(BOT)
	for step in 12000:
		m.step(bytes)
		_log_spawns(m.world, spawns)
		if m.phase != Match.PLAYING:
			return step
	return -1


## Appends each object that spawned since the last call (ids count up from 1 in a round): [id, kind, lane, kmh].
func _log_spawns(w: World, spawns: Array) -> void:
	for c: Traffic in w.traffic:
		if c.id > spawns.size():
			spawns.append([c.id, c.kind, Traffic.lane_of(std, c.x, c.w), c.kmh])


## The world's whole state but its step counter and the events of its last step.
static func _without_ticks(w: World) -> Array:
	var a := w.to_array()
	a[3 + World.SCALARS.find("tick")] = 0
	a[3 + World.SCALARS.find("events")] = 0
	for seat: Array in a[4 + World.SCALARS.size()]:
		seat[12] = 0
	return a
