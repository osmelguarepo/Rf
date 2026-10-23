extends "res://tests/test_case.gd"
## The game's versus rules (Config.game(), World.is_race()): no fuel, no car put out (a truck is a crash), fuel cars
## refill the nitro tank, the first car to the finish line wins the round (a bot as well as a person), and any seat wins
## the match with two round wins. Config.standard() keeps the first versus' elimination rules.

const H := preload("res://tests/sim_helpers.gd")
const Config := preload("res://scripts/sim/config.gd")
const World := preload("res://scripts/sim/world.gd")
const Match := preload("res://scripts/sim/match.gd")
const Car := preload("res://scripts/sim/car.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")

var game_cfg := Config.game()


func _versus(cfg: Config = game_cfg) -> World:
	return H.quiet_versus(cfg, 5, 3, 0b001)


func test_only_the_games_config_races() -> void:
	assert_true(_versus().is_race())
	assert_false(_versus(Config.standard()).is_race(), "the first versus keeps its elimination rules")
	assert_false(H.quiet_world(game_cfg).is_race(), "and the stage game is not a race")


func test_there_is_no_fuel_to_run_out_of() -> void:
	var w := _versus()
	H.run_bytes(w, [PlayerInput.encode(true, false, 0, false), PlayerInput.BOT, PlayerInput.BOT], 60 * 20)
	assert_eq(w.players[0].fuel, Config.FUEL_MAX, "fuel does not drain")
	assert_eq(w.players[0].alive, 1)


func test_a_truck_is_a_crash_not_the_end_of_the_car() -> void:
	var w := _versus()
	var car := w.players[0]
	car.speed = 200.0
	car.nitro_tank = 0.5
	H.on_car(w, Config.KIND_TRUCK, 0)
	H.run_bytes(w, [PlayerInput.NONE, PlayerInput.NONE, PlayerInput.NONE])
	assert_eq(car.alive, 1, "still in the race")
	assert_true((car.events & World.EV_CRASH) != 0)
	assert_lt(car.speed, 200.0 * 0.5, "most of its speed is lost")
	assert_gt(car.invulnerable, 0)
	assert_eq(car.nitro_tank, 0.0, "an accident empties the nitro tank")
	assert_eq(w.phase, World.RUNNING, "and the round goes on")


func test_a_fuel_car_refills_half_the_nitro_tank_and_pays_points() -> void:
	var w := _versus()
	var car := w.players[0]
	car.nitro_tank = 0.25
	car.nitro_progress = 100.0
	H.on_car(w, Config.KIND_FUEL_CAR, 0)
	H.run_bytes(w, [PlayerInput.NONE, PlayerInput.NONE, PlayerInput.NONE])
	assert_almost_eq(car.nitro_tank, 0.75, 1e-9)
	assert_eq(car.fuel, Config.FUEL_MAX, "fuel is untouched")
	assert_eq(car.score, Config.FUEL_CAR_POINTS)
	car.nitro_tank = 0.8
	H.on_car(w, Config.KIND_FUEL_CAR, 0)
	H.run_bytes(w, [PlayerInput.NONE, PlayerInput.NONE, PlayerInput.NONE])
	assert_eq(car.nitro_tank, 1.0, "a tank never holds more than full")


func test_the_first_car_across_the_line_starts_a_countdown_and_the_others_may_still_finish() -> void:
	var w := _versus()
	H.arrive_alone(w, 2)
	var idle := [PlayerInput.NONE, PlayerInput.NONE, PlayerInput.NONE]
	H.run_bytes(w, idle)
	assert_eq(w.players[2].finish_place, 1, "a bot's seat was first")
	assert_eq(w.players[2].alive, 0, "and it left the race")
	assert_eq(w.phase, World.RUNNING, "the others still race")
	assert_eq(w.finish_clock, 0)
	H.run_bytes(w, idle, game_cfg.race_finish_grace_ticks - 1)
	assert_eq(w.phase, World.RUNNING, "one step before the countdown ends")
	H.run_bytes(w, idle)
	assert_eq(w.phase, World.ROUND_OVER)
	assert_eq(w.winner, 2)
	assert_true((w.events & World.EV_ROUND_OVER) != 0)


func test_cars_still_racing_when_the_countdown_ends_are_placed_by_distance() -> void:
	var w := _versus()
	H.arrive_alone(w, 2)
	w.players[0].y_world -= 30.0
	var idle := [PlayerInput.NONE, PlayerInput.NONE, PlayerInput.NONE]
	H.run_bytes(w, idle, game_cfg.race_finish_grace_ticks + 1)
	assert_eq(w.phase, World.ROUND_OVER)
	assert_eq(w.standings(), [2, 1, 0] as Array[int], "the furthest back is last")
	assert_eq(w.players[0].finish_place, 0, "it never crossed")


func test_the_round_ends_at_once_when_every_car_has_crossed() -> void:
	var w := _versus()
	H.arrive_alone(w, 0)
	H.run_bytes(w, [PlayerInput.NONE, PlayerInput.NONE, PlayerInput.NONE])
	assert_eq(w.phase, World.RUNNING)
	w.players[1].y_world = game_cfg.race_finish_px + 1.0
	w.players[2].y_world = game_cfg.race_finish_px + 3.0
	H.run_bytes(w, [PlayerInput.NONE, PlayerInput.NONE, PlayerInput.NONE])
	assert_eq(w.phase, World.ROUND_OVER, "nobody is left to wait for")
	assert_eq(w.standings(), [0, 2, 1] as Array[int], "the first across, then the one further over the line")


func test_a_car_further_over_the_line_takes_the_better_place_in_a_step_with_two_arrivals() -> void:
	var w := _versus()
	H.arrive_alone(w, 0)
	w.players[0].y_world += 5.0
	w.players[1].y_world = game_cfg.race_finish_px + 9.0
	H.run_bytes(w, [PlayerInput.NONE, PlayerInput.NONE, PlayerInput.NONE])
	assert_eq([w.players[1].finish_place, w.players[0].finish_place], [1, 2])


func test_without_a_countdown_the_first_car_ends_the_round() -> void:
	var cfg := Config.game()
	cfg.race_finish_grace_ticks = 0
	var w := _versus(cfg)
	H.arrive_alone(w, 1)
	H.run_bytes(w, [PlayerInput.NONE, PlayerInput.NONE, PlayerInput.NONE])
	assert_eq(w.phase, World.ROUND_OVER)
	assert_eq(w.winner, 1)


func test_the_standard_profile_still_ends_a_round_when_a_truck_puts_a_human_out() -> void:
	var w := _versus(Config.standard())
	H.on_car(w, Config.KIND_TRUCK, 0)
	H.run_bytes(w, [PlayerInput.NONE, PlayerInput.NONE, PlayerInput.NONE])
	assert_eq(w.players[0].alive, 0)
	assert_eq(w.phase, World.ROUND_OVER)


func _confirm_next_round(m: Match) -> void:
	var idle := PackedByteArray([PlayerInput.NONE, PlayerInput.BOT, PlayerInput.BOT])
	for tick in Config.MATCH_CONFIRM_TICKS:
		m.step(idle)
	m.step(PackedByteArray([PlayerInput.CONFIRM, PlayerInput.BOT, PlayerInput.BOT]))
	H.quiet(m.world)


## Plays `order` (the seats of each race, best first) through a match of three seats whose seat 0 is a person.
func _play(m: Match, finishes: Array) -> void:
	var idle := PackedByteArray([PlayerInput.NONE, PlayerInput.BOT, PlayerInput.BOT])
	for order: Array in finishes:
		assert_eq(m.phase, Match.PLAYING)
		var line := m.world.cfg.race_finish_px
		m.world.camera_y = line
		for place in order.size():
			m.world.players[order[place]].y_world = line + 30.0 - 5.0 * place
		m.step(idle)
		if m.phase == Match.ROUND_OVER:
			_confirm_next_round(m)


func test_a_match_is_three_races_scored_by_place_and_a_bot_can_win_it() -> void:
	var m := Match.create(game_cfg, 9, 3, 0b001)
	H.quiet(m.world)
	_play(m, [[1, 0, 2], [1, 2, 0], [2, 1, 0]])
	assert_eq(m.phase, Match.MATCH_OVER)
	assert_eq(m.round_number, 3)
	assert_eq(m.race_points, [7 + 5 + 5, 10 + 10 + 7, 5 + 7 + 10] as Array[int])
	assert_eq(m.winner, 1, "the bot has the most points")
	assert_eq(m.points_order(), [1, 2, 0] as Array[int])
	assert_eq([m.race_place(0, 1), m.race_place(1, 0), m.race_place(2, 0)], [1, 3, 3])


func test_the_match_does_not_end_before_the_last_race() -> void:
	var m := Match.create(game_cfg, 9, 3, 0b001)
	H.quiet(m.world)
	_play(m, [[1, 0, 2], [1, 0, 2]])
	assert_eq(m.phase, Match.PLAYING, "two of three races are over")
	assert_eq(m.round_number, 3)


func test_level_on_points_the_better_place_in_the_last_race_wins() -> void:
	var m := Match.create(game_cfg, 9, 3, 0b001)
	H.quiet(m.world)
	# Seat 0: 10 + 5 + 7 = 22, seat 1: 7 + 10 + 5 = 22, seat 2: 5 + 7 + 10 = 22; seat 2 won the last race.
	_play(m, [[0, 1, 2], [1, 2, 0], [2, 0, 1]])
	assert_eq(m.race_points, [22, 22, 22] as Array[int])
	assert_eq(m.winner, 2)
	assert_eq(m.ranking_order(), [2, 0, 1] as Array[int])


func test_a_person_who_leaves_ranks_last_whatever_they_scored() -> void:
	var m := Match.create(game_cfg, 9, 3, 0b001)
	H.quiet(m.world)
	m.abandon(0)
	m.abandon(1)
	assert_eq(m.abandoned_mask, 1, "a bot's seat cannot leave")
	_play(m, [[0, 1, 2], [0, 1, 2], [0, 1, 2]])
	assert_eq(m.points_order(), [0, 1, 2] as Array[int])
	assert_eq(m.ranking_order(), [1, 2, 0] as Array[int], "seat 0 won every race but left")
	assert_eq(m.winner, 1)


func test_nothing_moves_during_the_start_countdown_and_the_race_starts_after_3_seconds() -> void:
	var w := World.versus(game_cfg, 5, 3, 0b001)
	assert_eq(w.countdown, 3 * Config.TICKS_PER_SECOND)
	var hold := [PlayerInput.encode(true, false, 0, true), PlayerInput.BOT, PlayerInput.BOT]
	H.run_bytes(w, hold, w.countdown)
	assert_eq(w.countdown, 0)
	for p: Car in w.players:
		assert_eq([p.speed, p.y_world, p.nitro_tank], [0.0, 0.0, 1.0], "seat %d still stands" % p.slot)
	assert_eq(w.stage_ticks, 0, "the difficulty clock waits too")
	H.run_bytes(w, hold)
	assert_gt(w.players[0].speed, 0.0, "green light")
	assert_eq(w.stage_ticks, 1)


func test_a_pause_during_the_countdown_holds_it_and_every_race_has_one() -> void:
	var m := Match.create(game_cfg, 9, 3, 0b001)
	var w := m.world
	var idle := PackedByteArray([PlayerInput.NONE, PlayerInput.BOT, PlayerInput.BOT])
	m.step(idle)
	var left := w.countdown
	m.step(PackedByteArray([PlayerInput.PAUSE, PlayerInput.BOT, PlayerInput.BOT]))
	m.step(idle)
	assert_eq(w.countdown, left, "paused: no tick passes")
	m.step(PackedByteArray([PlayerInput.PAUSE, PlayerInput.BOT, PlayerInput.BOT]))
	assert_eq(w.phase, World.RUNNING)
	w.countdown = 0
	H.quiet(w)
	H.arrive(w, 1)
	m.step(idle)
	assert_eq(m.phase, Match.ROUND_OVER)
	for tick in Config.MATCH_CONFIRM_TICKS:
		m.step(idle)
	m.step(PackedByteArray([PlayerInput.CONFIRM, PlayerInput.BOT, PlayerInput.BOT]))
	assert_eq(w.countdown, 3 * Config.TICKS_PER_SECOND, "the next race has its countdown")


func test_the_standard_profile_has_no_countdown() -> void:
	assert_eq(_versus(Config.standard()).countdown, 0)


func test_the_start_gantry_lights_five_reds_over_3_seconds_then_goes_out_with_go() -> void:
	var VersusHud := preload("res://scripts/view/versus_hud.gd")
	var w := World.versus(game_cfg, 5, 3, 0b001)
	var idle := [PlayerInput.NONE, PlayerInput.BOT, PlayerInput.BOT]
	var seen: Array[int] = []
	var go_at := -1
	for tick in 3 * Config.TICKS_PER_SECOND + 60:
		var lit := VersusHud.start_lights_lit(w)
		if seen.is_empty() or seen.back() != lit:
			seen.append(lit)
		if go_at < 0 and VersusHud.start_light(w) == "GO!":
			go_at = tick
		H.run_bytes(w, idle)
	assert_eq(seen, [1, 2, 3, 4, 5, 0] as Array[int], "one more light at a time, then all out")
	assert_gt(go_at, 3 * Config.TICKS_PER_SECOND - 1, "GO! only once the lights are out")
	assert_eq(VersusHud.start_light(_versus(Config.standard())), "", "no light without a countdown")
	assert_eq(VersusHud.start_lights_lit(_versus(Config.standard())), 0)
