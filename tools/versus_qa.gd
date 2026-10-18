extends "res://tools/tool_base.gd"
## The versus QA scenarios of docs/GODOT_PLAN.md §8 B3, played through the real screens (title, join screen, race,
## results) with synthetic pads, 18 000 frames per seed:
##
##   godot --headless --fixed-fps 60 --path . -s res://tools/versus_qa.gd -- --scenario=lone|six [OPTION...]
##   tools/run_tool.sh versus_qa            (both scenarios, as below)
##
## - lone (plan scenario a): one person against five bots. One pad joins, Right raises the bots to five, Start. The pad
##   drives its car (pad_autopilot()); in each match's first round, 30 s in, the pad disconnects
##   (Input.joy_connection_changed.emit(device, false)) and comes back 3 s later. It confirms between rounds and takes
##   the rematch.
## - six (plan scenario b): six people's seats driven by bot.gd. Six pads join and start; as soon as the round runs,
##   every pad disconnects, so every seat is an orphan human seat whose byte is 0xFF. Between rounds the first pad comes
##   back to confirm (orphan seats never confirm) and goes again once the next round runs.
##
## Options: --seeds=N [lone 1, six 20], --first-seed=S [1], --frames=F [18000 per seed].
##
## Checked on every step of the match (each frame is one fixed step at --fixed-fps 60):
## - a round ends only on the step a human seat goes out (EV_OUT on a human car), or, with one human, when no bot is
##   left;
## - no bot wins a round or the match;
## - a match ends with two round wins (or, with three humans or more, at the five-round cap; with one human, at two
##   wins or two losses);
## - no ERROR is logged.
## Measured (scenario six): the first elimination of each seed's first round, in running seconds (plan: median from 45
## to 180 s), and leader changes per running minute while the leader is still in the round (plan: at least one).
## Prints a line per seed and a summary; the last line is "versus_qa: PASS" when every check holds. Exit 0 or 1.

const Match := preload("res://scripts/sim/match.gd")

const SETTLE := 20
const PAD_BASE := 40
const QA_GUIDS_PREFIX := "qa-pad-"
## Lone scenario: when the pad disconnects in a match's first round (running ticks) and for how long (frames).
const UNPLUG_AT := 1800
const UNPLUG_FOR := 180
const MEDIAN_MIN := 45.0
const MEDIAN_MAX := 180.0
const LEADER_CHANGES_MIN := 1.0

var scenario := "six"
var seeds := 20
var first_seed := 1
var frames_per_seed := 18000

var _seed_index := 0
var _seed_frame := 0
var _phase := "boot"
var _pads: Array[int] = []
var _unplugged := {}
var _unplug_since := -1
var _unplugged_this_match := false
var _last_tick := -1
var _last_stage_ticks := 0
var _match: Match = null
var _leader := -1
var _first_out_seen := false
var _round_of_first := 0

# Per seed and totals.
var _seed_rounds := 0
var _seed_matches := 0
var _seed_first_out := -1.0
var rounds := 0
var matches := 0
var first_outs: Array[float] = []
var leader_changes := 0
var running_steps := 0
var violations: PackedStringArray = []
var multi_steps := 0
var human_round_wins := 0
var no_winner_rounds := 0
var reconnects_ok := 0


func _initialize() -> void:
	if not begin():
		finish(1)
		return
	scenario = user_arg("scenario", scenario)
	if scenario != "lone" and scenario != "six":
		printerr("versus_qa: unknown scenario %s (lone or six)" % scenario)
		finish(1)
		return
	seeds = user_arg("seeds", "1" if scenario == "lone" else "20").to_int()
	first_seed = user_arg("first-seed", "1").to_int()
	frames_per_seed = user_arg("frames", "18000").to_int()
	var count := 1 if scenario == "lone" else Config.VERSUS_SEATS_MAX
	for i in count:
		_pads.append(PAD_BASE + i)
	_start_seed()


func _start_seed() -> void:
	if app != null:
		for device: int in _pads:
			pad_let_go(device)
		app.get_parent().remove_child(app)
		app.free()
		app = null
	start_app(first_seed + _seed_index)
	_seed_frame = 0
	_phase = "title"
	_unplugged = {}
	_unplug_since = -1
	_match = null
	_last_tick = -1
	_seed_rounds = 0
	_seed_matches = 0
	_seed_first_out = -1.0


func _process(_delta: float) -> bool:
	if _finished:
		return false
	frame += 1
	_seed_frame += 1
	match _phase:
		"title":
			_title()
		"join":
			_join()
		"race":
			_race()
	if _seed_frame >= frames_per_seed:
		_end_seed()
	return false


func _title() -> void:
	if _seed_frame == 1:
		# The app booted on this frame (its _ready()); its seats exist from here on. Synthetic pads have no GUID.
		app.seats.guid_of = func(device: int) -> String: return QA_GUIDS_PREFIX + str(device)
	elif _seed_frame == SETTLE:
		tap(KEY_DOWN)
	elif _seed_frame == SETTLE + 4:
		tap(KEY_ENTER)
	elif _seed_frame > SETTLE + 4 and join_screen() != null:
		_phase = "join"
		_seed_frame_mark = _seed_frame


var _seed_frame_mark := 0


func _join() -> void:
	var t := _seed_frame - _seed_frame_mark
	for i in _pads.size():
		if t == 1 + 3 * i:
			pad_tap(_pads[i], JOY_BUTTON_A)
	var after := 3 * _pads.size() + 2
	if scenario == "lone" and t > after and t <= after + 8 and t % 2 == 0:
		pad_tap(_pads[0], JOY_BUTTON_DPAD_RIGHT)
	var start_at := after + (10 if scenario == "lone" else 0)
	if t == start_at:
		var expected := 5 if scenario == "lone" else 0
		if app.seats.bots != expected or app.seats.people() != _pads.size():
			_violation("join: %d people and %d bots, expected %d and %d" % [app.seats.people(), app.seats.bots, _pads.size(), expected])
		pad_tap(_pads[0], JOY_BUTTON_START)
	elif t > start_at + 2:
		if versus() == null:
			_violation("join: Start did not begin the race")
			_phase = "done"
			return
		_phase = "race"


func _race() -> void:
	var screen := versus()
	if screen == null:
		_violation("race: the race screen went away (frame %d)" % frame)
		_phase = "done"
		return
	var m: Match = screen.game_match
	if m != _match:
		_match = m
		_last_tick = m.world.tick
		_last_stage_ticks = m.world.stage_ticks
		_leader = -1
		_first_out_seen = false
		_unplugged_this_match = false
	else:
		_observe(m)
	_drive(screen, m)


## Checks the step the frame ran.
func _observe(m: Match) -> void:
	var w := m.world
	var stepped := w.tick - _last_tick
	_last_tick = w.tick
	if stepped == 0:
		return
	if stepped > 1:
		multi_steps += 1
		return
	if m.events & Match.EV_ROUND_START:
		_leader = -1
		_first_out_seen = false
	var running := w.stage_ticks == _last_stage_ticks + 1
	_last_stage_ticks = w.stage_ticks
	# The first elimination of the round.
	if not _first_out_seen:
		for p: Car in w.players:
			if p.events & World.EV_OUT:
				_first_out_seen = true
				if _seed_first_out < 0.0 and m.round_number == 1:
					_seed_first_out = w.stage_ticks / float(Config.TICKS_PER_SECOND)
				break
	# Leader changes while the leader is still in the round.
	if running:
		running_steps += 1
		var leader := -1
		for p: Car in w.players:
			if p.alive == 1 and (leader < 0 or p.y_world > w.players[leader].y_world):
				leader = p.slot
		if _leader >= 0 and leader >= 0 and leader != _leader and w.players[_leader].alive == 1:
			leader_changes += 1
		_leader = leader
	if m.events & Match.EV_ROUND_OVER:
		_round_over(m)
	if m.events & Match.EV_MATCH_OVER:
		_match_over(m)


func _round_over(m: Match) -> void:
	var w := m.world
	rounds += 1
	_seed_rounds += 1
	var humans := 0
	var human_out := false
	var bots_alive := 0
	for p: Car in w.players:
		if p.human == 1:
			humans += 1
			if p.events & World.EV_OUT:
				human_out = true
		elif p.alive == 1:
			bots_alive += 1
	if not human_out and not (humans == 1 and bots_alive == 0):
		_violation("round %d ended without a human going out on that step (seed %d)" % [m.round_number, _seed()])
	var won := m.last_round_winner()
	if won == Match.NO_WINNER:
		no_winner_rounds += 1
	elif w.players[won].human != 1:
		_violation("a bot (slot %d) won round %d (seed %d)" % [won, m.round_number, _seed()])
	else:
		human_round_wins += 1


func _match_over(m: Match) -> void:
	matches += 1
	_seed_matches += 1
	var w := m.world
	var humans := m.human_seats()
	if m.winner != Match.NO_WINNER:
		if w.players[m.winner].human != 1:
			_violation("a bot (slot %d) won the match (seed %d)" % [m.winner, _seed()])
		elif m.wins[m.winner] < Config.MATCH_WINS and not (humans.size() >= 3 and m.rounds_played() == Config.MATCH_ROUNDS_MAX):
			_violation("the match ended with %d wins for its winner (seed %d)" % [m.wins[m.winner], _seed()])
	elif humans.size() == 1:
		if m.losses(humans[0]) < Config.MATCH_LONE_LOSSES:
			_violation("a lone human's match ended without a winner after %d losses (seed %d)" % [m.losses(humans[0]), _seed()])
	elif m.rounds_played() < Config.MATCH_ROUNDS_MAX:
		var most := 0
		for i in humans:
			most = maxi(most, m.wins[i])
		if most >= Config.MATCH_WINS:
			_violation("a match with a two-round winner ended as a draw (seed %d)" % _seed())


## The pads' part: drive (lone), unplug and plug back, confirm between rounds, take the rematch.
func _drive(screen: Node, m: Match) -> void:
	var w := m.world
	var between := m.phase != Match.PLAYING
	var confirm_ready := between and m.phase_ticks >= Config.MATCH_CONFIRM_TICKS + 2
	if scenario == "lone":
		var device := _pads[0]
		if _unplugged.has(device):
			if frame - _unplug_since >= UNPLUG_FOR:
				Input.joy_connection_changed.emit(device, true)
				_unplugged.erase(device)
				if app.seats.seat_of(device) == 0 and not app.seats.is_orphan(0):
					reconnects_ok += 1
				else:
					_violation("the pad did not get its seat back (seed %d)" % _seed())
			return
		pad_autopilot(device, 160.0)
		if not between and not _unplugged_this_match and m.round_number == 1 and w.stage_ticks == UNPLUG_AT:
			pad_let_go(device)
			Input.joy_connection_changed.emit(device, false)
			_unplugged[device] = true
			_unplug_since = frame
			_unplugged_this_match = true
			if not app.seats.is_orphan(0) or app.seats.seat_byte(0) != 0xFF:
				_violation("the seat was not handed to a bot when its pad went away (seed %d)" % _seed())
		elif confirm_ready and (frame % 30) == 0:
			pad_press_a(device)
		return
	# six
	if not between and w.phase == World.RUNNING and _unplugged.size() < _pads.size():
		for device: int in _pads:
			if not _unplugged.has(device):
				pad_let_go(device)
				Input.joy_connection_changed.emit(device, false)
				_unplugged[device] = true
	elif confirm_ready:
		var device := _pads[0]
		if _unplugged.has(device):
			Input.joy_connection_changed.emit(device, true)
			_unplugged.erase(device)
		elif (frame % 30) == 0:
			pad_press_a(device)


func _seed() -> int:
	return first_seed + _seed_index


func _violation(text: String) -> void:
	if violations.size() < 50:
		printerr("versus_qa: FAIL: " + text)
	violations.append(text)


func _end_seed() -> void:
	if _seed_first_out >= 0.0:
		first_outs.append(_seed_first_out)
	print("versus_qa %s: seed %d: %d rounds, %d matches decided, first elimination %s" % [
		scenario, _seed(), _seed_rounds, _seed_matches,
		("%.1f s" % _seed_first_out) if _seed_first_out >= 0.0 else "none"])
	_seed_index += 1
	if _seed_index < seeds:
		_start_seed()
	else:
		_report()


func _report() -> void:
	_phase = "done"
	var minutes := running_steps / float(Config.TICKS_PER_SECOND * 60)
	var per_minute := leader_changes / minutes if minutes > 0.0 else 0.0
	first_outs.sort()
	var median := -1.0
	if not first_outs.is_empty():
		var n := first_outs.size()
		var mid := floori(n / 2.0)
		median = first_outs[mid] if n % 2 == 1 else (first_outs[mid - 1] + first_outs[mid]) / 2.0
	print("versus_qa %s: %d seeds, %d rounds (%d won by a human, %d without a winner), %d matches decided" % [
		scenario, seeds, rounds, human_round_wins, no_winner_rounds, matches])
	print("versus_qa %s: first elimination of the first round: median %.1f s over %d seeds (min %.1f, max %.1f)" % [
		scenario, median, first_outs.size(), first_outs[0] if not first_outs.is_empty() else -1.0,
		first_outs[-1] if not first_outs.is_empty() else -1.0])
	print("versus_qa %s: leader changes %.2f per running minute (%.1f minutes); reconnects %d; frames with several steps %d" % [
		scenario, per_minute, minutes, reconnects_ok, multi_steps])
	var ok := violations.is_empty() and rounds > 0
	if scenario == "six":
		if median < MEDIAN_MIN or median > MEDIAN_MAX:
			ok = false
			printerr("versus_qa: FAIL: the median first elimination %.1f s is outside %d..%d s" % [median, MEDIAN_MIN, MEDIAN_MAX])
		if per_minute < LEADER_CHANGES_MIN:
			ok = false
			printerr("versus_qa: FAIL: %.2f leader changes per minute, fewer than %d" % [per_minute, LEADER_CHANGES_MIN])
	if scenario == "lone" and reconnects_ok == 0:
		ok = false
		printerr("versus_qa: FAIL: the pad never disconnected and came back")
	print("versus_qa %s: %d violations, errors %d" % [scenario, violations.size(), errors().size()])
	if ok:
		finish(0, "versus_qa: PASS")
	else:
		print("versus_qa: FAIL")
		finish(1)
