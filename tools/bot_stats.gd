extends SceneTree
## How bots play (docs/HANDOFF.md, B1 part 2; the numbers B3 checks in plan §8 B3): matches of versus rounds with every
## seat driven by bot.gd, one per seed, measured. Pure simulation, no window, no game scene:
##
##   godot --headless --path . -s res://tools/bot_stats.gd [-- OPTION...]
##
## Options (defaults in brackets): --seeds=N [20], --first-seed=S [1], --ticks=T [18000, 5 minutes], --seats=N [6],
## --humans=MASK [every seat; decimal, or binary as 0b...], --rounds (a line per round), and --set=FIELD=VALUE, any
## number of times, to try another value of a field of the standard profile (Config.standard()), such as
## --set=bot_truck_caution=48 or --set=versus_gap_min=56.25 (constants such as EDGE_FUEL_DRAIN_PER_SEC need an edit of
## scripts/sim/config.gd). Run the project's import once first (tools/test.sh does), as for every tool.
##
## Each seed plays Match.create(Config.standard(), seed, seats, humans) for T steps. Every seat's byte is 0xFF, so
## bot.gd drives humans and bots alike; while the match waits between rounds, the lowest human seat sends a confirm
## press, so the next round starts Config.MATCH_CONFIRM_TICKS steps after the last ended. A seed stops when its match
## is decided.
##
## It prints one line per seed, then the summary:
## - the first elimination of each round (any seat out; with every seat human it ends the round), in running seconds:
##   the median of the first rounds (one per seed) and of all rounds;
## - leader changes per minute of running time, in two counts. The leader is the live car furthest ahead after each
##   running step (the camera's car; the lower seat on a tie). A racing change: another car leads while the car that
##   led is still in the round. A handover: the car that led went out in the step and the next car takes the lead
##   without passing it; with every seat human that happens only in a round's last step (the summary says how many
##   were). The per-round spread counts the racing changes;
## - how rounds end: the seats that went out in the step that ended each round, by a truck or with an empty tank (and
##   of those, how many were touching the bottom edge on their last step), and rounds where several went out at once;
## - share of running time cars spent touching the bottom edge, and on top of another car (hitboxes overlapping);
## - fuel cars taken, roadside crashes, bumps and oil skids per car and minute; round winners and match results.
## Exit code 0, or 1 on a bad option.

const Config := preload("res://scripts/sim/config.gd")
const World := preload("res://scripts/sim/world.gd")
const Match := preload("res://scripts/sim/match.gd")
const Car := preload("res://scripts/sim/car.gd")
const Collision := preload("res://scripts/sim/collision.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")

var seeds := 20
var first_seed := 1
var ticks := 18000
var seats := 6
var humans := -1
var per_round := false
## [field, value] pairs from --set=.
var overrides: Array = []


func _initialize() -> void:
	if not _read_options():
		quit(1)
		return
	if humans < 0:
		humans = (1 << seats) - 1
	var cfg := Config.standard()
	for pair: Array in overrides:
		if not (pair[0] in cfg) or typeof(cfg.get(pair[0])) not in [TYPE_INT, TYPE_FLOAT]:
			printerr("bot_stats: --set: Config.standard() has no number field %s" % pair[0])
			quit(1)
			return
		cfg.set(pair[0], int(pair[1]) if typeof(cfg.get(pair[0])) == TYPE_INT else float(pair[1]))
		print("bot_stats: %s = %s" % [pair[0], cfg.get(pair[0])])
	if not World.versus_valid(cfg, seats, humans):
		printerr("bot_stats: %d seats with humans 0b%s is not a versus game" % [seats, String.num_int64(humans, 2)])
		quit(1)
		return
	var started := Time.get_ticks_msec()
	print("bot_stats: %d seeds from %d, up to %d ticks each, %d seats, humans 0b%s, every seat driven by bot.gd (0xFF)" % [
		seeds, first_seed, ticks, seats, String.num_int64(humans, 2)
	])
	var total := _new_totals()
	for i in seeds:
		_play(cfg, first_seed + i, total)
	_summary(total)
	print("bot_stats: ran in %.1f s" % ((Time.get_ticks_msec() - started) / 1000.0))
	quit(0)


func _read_options() -> bool:
	for argument in OS.get_cmdline_user_args():
		var value := argument.get_slice("=", 1)
		if argument.begins_with("--seeds="):
			seeds = int(value)
		elif argument.begins_with("--first-seed="):
			first_seed = int(value)
		elif argument.begins_with("--ticks="):
			ticks = int(value)
		elif argument.begins_with("--seats="):
			seats = int(value)
		elif argument.begins_with("--humans="):
			humans = value.substr(2).bin_to_int() if value.begins_with("0b") else int(value)
		elif argument == "--rounds":
			per_round = true
		elif argument.begins_with("--set=") and argument.get_slice_count("=") == 3:
			overrides.append([argument.get_slice("=", 1), argument.get_slice("=", 2)])
		else:
			printerr("bot_stats: unknown option %s" % argument)
			return false
	return seeds > 0 and ticks > 0


func _new_totals() -> Dictionary:
	return {
		"first_rounds": [], "all_rounds": [], "round_lengths": [], "leader_changes": 0, "leader_handovers": 0,
		"handovers_at_end": 0, "running_ticks": 0, "leader_rates": [], "ends_truck": 0, "ends_dry": 0,
		"ends_dry_edge": 0, "ends_several": 0, "rounds": 0, "rounds_won": 0, "rounds_no_winner": 0,
		"matches_decided": 0, "matches_won": 0, "match_rounds": [], "car_ticks": 0, "edge_ticks": 0,
		"pair_ticks": 0, "stacked_ticks": 0, "pickups": 0, "crashes": 0, "bumps": 0, "skids": 0,
		"bot_outs_before_end": 0,
	}


## One seed: a match until it is decided or the ticks run out.
func _play(cfg: Config, seed_value: int, total: Dictionary) -> void:
	var m := Match.create(cfg, seed_value, seats, humans)
	var confirm_seat: int = m.human_seats()[0]
	var bytes := PackedByteArray()
	bytes.resize(seats)
	var leader := -1
	var first_out := -1
	var changes := 0
	var handovers := 0
	var running := 0
	var touching: Array[int] = []
	touching.resize(seats)
	var line := "seed %d:" % seed_value
	for tick in ticks:
		bytes.fill(PlayerInput.BOT)
		if m.phase == Match.ROUND_OVER:
			bytes[confirm_seat] = PlayerInput.CONFIRM | PlayerInput.STEER_NONE
		var was_playing := m.phase == Match.PLAYING and m.world.phase == World.RUNNING
		for p: Car in m.world.players:
			touching[p.slot] = p.touching_edge
		m.step(bytes)
		var w := m.world
		if was_playing:
			running += 1
			total["running_ticks"] += 1
			var now := _leader(w)
			if now >= 0:
				if leader >= 0 and now != leader:
					if w.players[leader].alive != 0:
						changes += 1
						total["leader_changes"] += 1
					else:
						handovers += 1
						total["leader_handovers"] += 1
						if (m.events & Match.EV_ROUND_OVER) != 0:
							total["handovers_at_end"] += 1
				leader = now
			_count_cars(w, total)
			for p: Car in w.players:
				if (p.events & World.EV_OUT) != 0 and first_out < 0:
					first_out = w.stage_ticks
		if (m.events & Match.EV_ROUND_OVER) != 0:
			var record := _end_of_round(w, touching, total)
			var seconds := first_out / 60.0
			total["all_rounds"].append(seconds)
			total["round_lengths"].append(w.stage_ticks / 60.0)
			if m.round_number == 1:
				total["first_rounds"].append(seconds)
			if running > 0:
				total["leader_rates"].append(changes * 3600.0 / running)
			line += " r%d %.1fs %s%s;" % [m.round_number, w.stage_ticks / 60.0, record, _winner_text(w.winner)]
			if per_round:
				print("  seed %d round %d: first out %.1f s, round %.1f s, %s, leader changes %d racing (%.1f a minute) and %d handovers, scores %s" % [
					seed_value, m.round_number, seconds, w.stage_ticks / 60.0, record, changes,
					changes * 3600.0 / maxi(running, 1), handovers, _scores(w)
				])
			leader = -1
			first_out = -1
			changes = 0
			handovers = 0
			running = 0
		if m.phase == Match.MATCH_OVER:
			break
	if m.phase == Match.MATCH_OVER:
		total["matches_decided"] += 1
		total["match_rounds"].append(m.rounds_played())
		if m.winner != Match.NO_WINNER:
			total["matches_won"] += 1
		line += " match over after %d rounds,%s wins %s" % [m.rounds_played(), _winner_text(m.winner), m.wins]
	else:
		line += " match not decided in %d ticks, wins %s" % [ticks, m.wins]
	print(line)


## The live car furthest ahead, the lower seat on a tie (World._leader()'s rule); -1 if none.
static func _leader(w: World) -> int:
	var best: Car = null
	for p: Car in w.players:
		if p.alive != 0 and (best == null or p.y_world > best.y_world):
			best = p
	return -1 if best == null else best.slot


func _count_cars(w: World, total: Dictionary) -> void:
	for p: Car in w.players:
		if (p.events & World.EV_OUT) != 0:
			if w.phase == World.RUNNING and p.human == 0:
				total["bot_outs_before_end"] += 1
			continue
		if p.alive == 0:
			continue
		total["car_ticks"] += 1
		total["edge_ticks"] += p.touching_edge
		if (p.events & World.EV_PICKUP) != 0:
			total["pickups"] += 1
		if (p.events & World.EV_CRASH) != 0:
			total["crashes"] += 1
		if (p.events & World.EV_BUMP) != 0:
			total["bumps"] += 1
		if (p.events & World.EV_SKID) != 0:
			total["skids"] += 1
	for a in w.players.size():
		for b in range(a + 1, w.players.size()):
			var p := w.players[a]
			var q := w.players[b]
			if p.alive == 0 or q.alive == 0:
				continue
			total["pair_ticks"] += 1
			if Collision.overlaps(p.x, -p.y_world, p.w, p.h, q.x, -q.y_world, q.w, q.h):
				total["stacked_ticks"] += 1


## "seat:cause" for each seat out in the round's last step; touching is each seat's touching_edge before that step.
func _end_of_round(w: World, touching: Array[int], total: Dictionary) -> String:
	total["rounds"] += 1
	if w.winner == World.NO_WINNER:
		total["rounds_no_winner"] += 1
	else:
		total["rounds_won"] += 1
	var parts: Array[String] = []
	for p: Car in w.players:
		if (p.events & World.EV_OUT) == 0:
			continue
		if p.fuel > 0.0:
			total["ends_truck"] += 1
			parts.append("%d:truck" % p.slot)
		else:
			total["ends_dry"] += 1
			var edge := touching[p.slot] != 0
			if edge:
				total["ends_dry_edge"] += 1
			parts.append("%d:dry%s" % [p.slot, "@edge" if edge else ""])
	if parts.size() > 1:
		total["ends_several"] += 1
	return "out " + ",".join(parts)


static func _winner_text(seat: int) -> String:
	return " no winner" if seat == World.NO_WINNER else " winner %d" % seat


static func _scores(w: World) -> Array:
	var out: Array = []
	for p: Car in w.players:
		out.append(p.score)
	return out


func _summary(t: Dictionary) -> void:
	var minutes: float = float(t["running_ticks"]) / 3600.0
	var cars: float = maxf(float(t["car_ticks"]), 1.0) / 3600.0
	print("")
	print("first elimination, first round of each seed: %s" % _spread(t["first_rounds"]))
	print("first elimination, all rounds: %s" % _spread(t["all_rounds"]))
	print("round length, all rounds: %s" % _spread(t["round_lengths"]))
	print("leader changes while racing (the car that led still in the round): %d, %.2f a minute over %.1f running minutes; per round: %s" % [
		t["leader_changes"], t["leader_changes"] / maxf(minutes, 1e-9), minutes, _spread(t["leader_rates"], "")
	])
	print("leader handovers (the car that led went out in the step): %d, %.2f a minute; %d of them in a round's last step" % [
		t["leader_handovers"], t["leader_handovers"] / maxf(minutes, 1e-9), t["handovers_at_end"]
	])
	print("rounds: %d, ended by %d seats out by a truck and %d with an empty tank (%d of them touching the bottom edge); %d rounds with several out at once" % [
		t["rounds"], t["ends_truck"], t["ends_dry"], t["ends_dry_edge"], t["ends_several"]
	])
	print("bots out before their round ended: %d" % t["bot_outs_before_end"])
	print("round winners: %d rounds won, %d without a winner" % [t["rounds_won"], t["rounds_no_winner"]])
	print("matches decided: %d of %d (%d with a winner), rounds per match: %s" % [
		t["matches_decided"], seeds, t["matches_won"], _spread(t["match_rounds"], "")
	])
	print("time touching the bottom edge: %.1f %% of car time; on top of another car: %.1f %% of pair time" % [
		100.0 * t["edge_ticks"] / maxi(t["car_ticks"], 1), 100.0 * t["stacked_ticks"] / maxi(t["pair_ticks"], 1)
	])
	print("per car and minute: %.2f fuel cars, %.2f roadside crashes, %.2f bumps, %.2f oil skids" % [
		t["pickups"] / cars, t["crashes"] / cars, t["bumps"] / cars, t["skids"] / cars
	])


## "median M (min A, quartiles Q1 to Q3, max B; n N)" of a list of numbers.
static func _spread(values: Array, unit: String = " s") -> String:
	if values.is_empty():
		return "none"
	var v := values.duplicate()
	v.sort()
	return "median %.1f%s (min %.1f, quartiles %.1f to %.1f, max %.1f; n %d)" % [
		_quantile(v, 0.5), unit, float(v[0]), _quantile(v, 0.25), _quantile(v, 0.75), float(v[v.size() - 1]), v.size()
	]


## Linear interpolation between the closest ranks of a sorted list.
static func _quantile(sorted: Array, q: float) -> float:
	var at := q * (sorted.size() - 1)
	var low := floori(at)
	var high := mini(low + 1, sorted.size() - 1)
	return float(sorted[low]) + (float(sorted[high]) - float(sorted[low])) * (at - low)
