extends RefCounted
## A versus match (docs/GODOT_PLAN.md §7 "Partida"): rounds of one versus World until the match is decided, best of
## three. Pure and deterministic like World: step() takes one input byte per seat, and the same seed and bytes give
## the same match (checksum()). Rounds follow each other on input bytes, so a match replays exactly, over the network
## too.
##
## Phases:
## - PLAYING: a round is under way; `world` runs it (its own phase is RUNNING or PAUSED).
## - ROUND_OVER: the round has ended and the match is not decided. The results wait for a confirm press: from
##   Config.MATCH_CONFIRM_TICKS steps after the round ended (1 s), a confirm press from any human seat starts the next
##   round. Bot seats never confirm, and neither does the bot byte 0xFF, so a human seat whose controller went away
##   cannot either.
## - MATCH_OVER: the match is decided (`winner`, or NO_WINNER). It takes no input any more; what comes next (a new
##   match, the title) is the app's to decide.
##
## The match is decided at the end of a round:
## - With several humans, by the first to Config.MATCH_WINS (2) round wins. Three or more can share the wins (1-1-1),
##   so after Config.MATCH_ROUNDS_MAX (5) rounds the match goes to the most wins, then the most points over the rounds,
##   then the most distance over the rounds; level on all three, nobody wins it.
## - With a single human, by the human's MATCH_WINS wins (the human wins it) or Config.MATCH_LONE_LOSSES rounds the
##   human did not win (nobody wins it: bots never win).
## A round nobody won (World.winner NO_WINNER) counts for nobody: no win for anyone, one round more played (and, with a
## single human, a round the human did not win).
##
## A race match (World.is_race(), the game's rules; docs/SPEC_RANKING.md) is Config.match_races races. Each race gives every seat
## Config.RACE_POINTS by its place (World.standings()); the most race points win the match, a tie going to the better place
## in the last race, so some seat, a bot's too, always does. A person given the bot byte 0xFF leaves the match
## (abandoned_mask) and ranks last in ranking_order().
##
## Each round starts afresh (World.start_round()): points, distance, fuel, traffic, gaps, the difficulty clock and the
## bots. The world's RNG, the seats' and the bots' streams go on from the round before, so every round is new and the
## whole match still follows from its seed.

const Self := preload("res://scripts/sim/match.gd")
const Config := preload("res://scripts/sim/config.gd")
const World := preload("res://scripts/sim/world.gd")
const Car := preload("res://scripts/sim/car.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")

## Layout version of to_array().
const FORMAT := 2

const PLAYING := 0
const ROUND_OVER := 1
const MATCH_OVER := 2
const PHASE_NAMES := ["playing", "round_over", "match_over"]

## Events of the last step, as bits (the world's own are in world.events).
## A round ended this step (also when it decided the match).
const EV_ROUND_OVER := 1
## The match was decided this step.
const EV_MATCH_OVER := 2
## A confirm press started the next round this step.
const EV_ROUND_START := 4
const EVENT_NAMES := ["round_over", "match_over", "round_start"]

## winner while the match is not decided, or when nobody won it. Also World.winner's value for a round nobody won.
const NO_WINNER := World.NO_WINNER

## The scalar fields, in to_array() order.
const SCALARS := ["phase", "round_number", "winner", "phase_ticks", "events", "abandoned_mask"]

## The world of the round being played (or just played). Its fields are what the race screen draws.
var world: World
var phase: int = PLAYING
## The round being played, or just played: 1 for the first.
var round_number: int = 1
## The seat that won the match, once phase is MATCH_OVER; NO_WINNER until then, or when nobody won it.
var winner: int = NO_WINNER
## Steps since the phase began (the round-over screen's clock: confirm counts from MATCH_CONFIRM_TICKS).
var phase_ticks: int = 0
var events: int = 0
## Per seat: rounds won.
var wins: Array[int] = []
## Per seat: points scored in the rounds finished so far (Car.score at each round's end).
var totals: Array[int] = []
## Per seat: distance driven in the rounds finished so far (Car.distance at each round's end).
var distances: Array[float] = []
## The winner of each round finished so far, in order, NO_WINNER for a round nobody won.
var round_winners: Array[int] = []
## Race match, per seat: race points over the races finished (Config.RACE_POINTS by place).
var race_points: Array[int] = []
## Race match: the seats in finishing order, best first, of each race finished so far, one race after the other (so
## `players` seats per race).
var race_order: Array[int] = []
## Race match: the seats (a bit each) of people who left the match. They rank last in it, whatever they scored.
var abandoned_mask: int = 0


## A match of p_seats seats, seat s a person's if p_humans has its bit (1 << s): World.versus() and its rules. null
## (with an error) when World.versus_valid() is false.
static func create(p_cfg: Config, p_seed: int, p_seats: int, p_humans: int) -> Self:
	if not World.versus_valid(p_cfg, p_seats, p_humans):
		push_error("Match.create: needs the standard profile, %d to %d seats and at least one human seat" % [
			Config.VERSUS_SEATS_MIN, Config.VERSUS_SEATS_MAX
		])
		return null
	var m := Self.new()
	m.world = World.versus(p_cfg, p_seed, p_seats, p_humans)
	for i in p_seats:
		m.wins.append(0)
		m.totals.append(0)
		m.distances.append(0.0)
		m.race_points.append(0)
	return m


## Advances one tick. One byte per seat, as World.step(): 0xFF hands a seat to its bot. The world steps in every
## phase (it takes no input once its round is over, but counts the tick). PLAYING: when the world's round ends, the
## match counts it and becomes ROUND_OVER or MATCH_OVER. ROUND_OVER: a confirm press from a human seat, from
## MATCH_CONFIRM_TICKS steps after the round ended, starts the next round, whose first step is the next one.
func step(inputs: PackedByteArray) -> void:
	events = 0
	phase_ticks += 1
	if world.is_race() and phase != MATCH_OVER:
		for p: Car in world.players:
			if p.human != 0 and p.slot < inputs.size() and PlayerInput.is_bot(inputs[p.slot]):
				abandon(p.slot)
	world.step(inputs)
	if phase == PLAYING:
		if world.phase == World.ROUND_OVER:
			_end_round()
	elif phase == ROUND_OVER:
		if phase_ticks >= Config.MATCH_CONFIRM_TICKS and human_confirmed(inputs):
			_next_round()


## True when a human seat's byte has the confirm bit (the bot byte 0xFF never has).
func human_confirmed(inputs: PackedByteArray) -> bool:
	for p: Car in world.players:
		if p.human != 0 and p.slot < inputs.size() and PlayerInput.confirm(inputs[p.slot]):
			return true
	return false


## The winner of the last round finished, or NO_WINNER (also before the first one ends).
func last_round_winner() -> int:
	return NO_WINNER if round_winners.is_empty() else round_winners[round_winners.size() - 1]


## Rounds finished so far.
func rounds_played() -> int:
	return round_winners.size()


## Rounds finished that this seat did not win. With a single human, the rounds the human lost.
func losses(seat: int) -> int:
	return round_winners.size() - wins[seat]


## The human seats, in seat order.
func human_seats() -> Array[int]:
	var seats: Array[int] = []
	for p: Car in world.players:
		if p.human != 0:
			seats.append(p.slot)
	return seats


## Counts the round that just ended: the world's winner gets a win, every seat adds its points and distance. Then the
## match is decided or waits for the next round.
func _end_round() -> void:
	var round_winner := world.winner
	round_winners.append(round_winner)
	if world.is_race():
		_score_race()
	if round_winner != NO_WINNER:
		wins[round_winner] += 1
	for p: Car in world.players:
		totals[p.slot] += p.score
		distances[p.slot] += p.distance
	events |= EV_ROUND_OVER
	phase_ticks = 0
	if _decide():
		phase = MATCH_OVER
		events |= EV_MATCH_OVER
	else:
		phase = ROUND_OVER


## True when the match is decided after the rounds so far; sets `winner`.
func _decide() -> bool:
	if world.is_race():
		return _decide_race()
	var humans := human_seats()
	if humans.size() == 1:
		var lone := humans[0]
		if wins[lone] >= Config.MATCH_WINS:
			winner = lone
			return true
		return losses(lone) >= Config.MATCH_LONE_LOSSES
	for seat: int in humans:
		if wins[seat] >= Config.MATCH_WINS:
			winner = seat
			return true
	if round_winners.size() < Config.MATCH_ROUNDS_MAX:
		return false
	var best := -1
	var level := false
	for seat: int in humans:
		if best < 0:
			best = seat
			continue
		var order := _rank(seat, best)
		if order > 0:
			best = seat
			level = false
		elif order == 0:
			level = true
	winner = NO_WINNER if level else best
	return true


## 1 if seat a ranks above seat b over the match, -1 if below, 0 if level: more wins, then more points, then more
## distance.
func _rank(a: int, b: int) -> int:
	if wins[a] != wins[b]:
		return 1 if wins[a] > wins[b] else -1
	if totals[a] != totals[b]:
		return 1 if totals[a] > totals[b] else -1
	if distances[a] != distances[b]:
		return 1 if distances[a] > distances[b] else -1
	return 0


func _next_round() -> void:
	round_number += 1
	world.start_round()
	phase = PLAYING
	phase_ticks = 0
	events |= EV_ROUND_START


## Every field of the match, as plain ints, floats and arrays: [FORMAT, SCALARS..., wins, totals, distances,
## round_winners, world.to_array()].
func to_array() -> Array:
	var a: Array = [FORMAT]
	for field: String in SCALARS:
		a.append(get(field))
	for values: Array in [wins, totals, distances, round_winners, race_points, race_order]:
		var plain: Array = []
		plain.append_array(values)
		a.append(plain)
	a.append(world.to_array())
	return a


## Rebuilds a match from to_array(). p_cfg must be the profile the array was made with.
static func from_array(p_cfg: Config, a: Array) -> Self:
	if a.size() != 8 + SCALARS.size() or a[0] != FORMAT:
		push_error("Match.from_array: wrong format")
		return null
	var m := Self.new()
	for i in SCALARS.size():
		m.set(SCALARS[i], a[1 + i])
	var at := 1 + SCALARS.size()
	m.wins.assign(a[at])
	m.totals.assign(a[at + 1])
	m.distances.assign(a[at + 2])
	m.round_winners.assign(a[at + 3])
	m.race_points.assign(a[at + 4])
	m.race_order.assign(a[at + 5])
	m.world = World.from_array(p_cfg, a[at + 6])
	return m


## SHA-256 of the serialised state, the world's included. Two matches with the same checksum are the same match.
func checksum() -> String:
	return var_to_bytes(to_array()).hex_encode().sha256_text()


func clone() -> Self:
	var m := Self.new()
	for field: String in SCALARS:
		m.set(field, get(field))
	m.wins = wins.duplicate()
	m.totals = totals.duplicate()
	m.distances = distances.duplicate()
	m.round_winners = round_winners.duplicate()
	m.race_points = race_points.duplicate()
	m.race_order = race_order.duplicate()
	m.world = world.clone()
	return m


## A race match (World.is_race()): decided after cfg.match_races races, by the most race points; a tie goes to the one
## who placed better in the last race, so some seat, a bot's too, always wins it.
func _decide_race() -> bool:
	if round_winners.size() < world.cfg.match_races:
		return false
	winner = ranking_order()[0]
	return true


## Counts the race that just ended: its places and their race points.
func _score_race() -> void:
	var order := world.standings()
	race_order.append_array(order)
	for place in order.size():
		race_points[order[place]] += Config.RACE_POINTS[mini(place, Config.RACE_POINTS.size() - 1)]


## Race match: the seats by race points, best first; level seats by their place in the last race.
func points_order() -> Array[int]:
	var seats := world.players.size()
	var last: Array = race_order.slice(race_order.size() - seats) if race_order.size() >= seats else []
	var order: Array[int] = []
	for p: Car in world.players:
		order.append(p.slot)
	order.sort_custom(func(a: int, b: int) -> bool:
		if race_points[a] != race_points[b]:
			return race_points[a] > race_points[b]
		return last.find(a) < last.find(b))
	return order


## Race match: the order the ranking uses, best first. As points_order(), but a person who left the match is last.
func ranking_order() -> Array[int]:
	var order: Array[int] = []
	var left: Array[int] = []
	for slot: int in points_order():
		if (abandoned_mask & (1 << slot)) != 0:
			left.append(slot)
		else:
			order.append(slot)
	order.append_array(left)
	return order


## A person leaves the match for good (their seat's bot drives on): in the ranking they take the last place.
func abandon(slot: int) -> void:
	if world.players[slot].human != 0:
		abandoned_mask |= 1 << slot


## Race match: the place (1 for the first) of a seat in race number `race` (0 for the first); 0 for a race not played.
func race_place(race: int, slot: int) -> int:
	var seats := world.players.size()
	for place in seats:
		if (race + 1) * seats <= race_order.size() and race_order[race * seats + place] == slot:
			return place + 1
	return 0
