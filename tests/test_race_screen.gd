extends "res://tests/test_case.gd"
## The versus race screen (B2, scripts/app/versus.gd) through a real App and synthetic joypad events
## (tests/screen_helpers.gd): a Match of the join screen's line-up, one byte per seat (the pad's, or 0xFF for a bot and
## for a pad that has gone), pause by any person and quit to the title, the pause on focus loss, a round played to its
## end and the confirm that counts only after Config.MATCH_CONFIRM_TICKS, the match's end with a rematch (the next
## seed, the same seats) or the join screen, pads going away and coming back, and what the HUD shows.

const S := preload("res://tests/screen_helpers.gd")
const SimHelpers := preload("res://tests/sim_helpers.gd")
const App := preload("res://scripts/app/app.gd")
const Seats := preload("res://scripts/input/seats.gd")
const Config := preload("res://scripts/sim/config.gd")
const World := preload("res://scripts/sim/world.gd")
const Match := preload("res://scripts/sim/match.gd")
const Car := preload("res://scripts/sim/car.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")
const Held := preload("res://scripts/input/held.gd")
const VersusHud := preload("res://scripts/view/versus_hud.gd")
const Cars := preload("res://scripts/view/cars.gd")
const PlayerColours := preload("res://scripts/view/player_colours.gd")
const ViewConfig := preload("res://scripts/view/view_config.gd")
const Draw := preload("res://scripts/view/draw.gd")
const Hud := preload("res://scripts/view/hud.gd")

const SEED := 11
const PADS: Array[int] = [50, 51, 52, 55, 56, 57, 58]
## Keys that drive the single-player car when held: nitro, throttle (two of its keys) and steering.
const KEYS_HELD: Array[Key] = [KEY_X, KEY_UP, KEY_Z, KEY_LEFT]

var app: App
var seats: Seats
## device -> GUID for the seats' fake source.
var guids := {}


func before_each() -> void:
	guids = {}
	app = S.boot(SEED)
	seats = app.seats
	seats.guid_of = func(device: int) -> String: return guids.get(device, "")


func after_each() -> void:
	# The fake source refers to this test: let go of it, or the seats and the test are never freed.
	seats.guid_of = Callable()
	seats = null
	S.free_app(app)
	app = null
	S.release(PADS)


func test_the_race_plays_a_match_of_the_line_up() -> void:
	var race := _race([50, 51], 1)
	var m: Match = race.game_match
	assert_eq(S.screen_name(app), "Versus")
	assert_eq(m.world.mode, World.MODE_VERSUS)
	assert_eq(m.world.game_seed, SEED, "the session's seed")
	assert_eq(m.world.players.size(), 3)
	var humans: Array[int] = []
	for p: Car in m.world.players:
		humans.append(p.human)
	assert_eq(humans, [1, 1, 0] as Array[int])
	assert_eq(race.lineup, [0, 1, 2] as Array[int])
	assert_eq(race.cars.seat_colours, race.lineup, "each car in its seat's colour")
	assert_eq(race.hud.lineup, race.lineup, "each panel its seat's")
	assert_eq(app.input, seats)
	S.frame(app, 3)
	assert_eq(m.world.tick, 3, "the clock's steps")


## Seats keep their colour whatever their world slot: two people on seats 0 and 4 (the ones between them left) race in
## slots 0 and 1, the cars and panels in the colours of seats 0 and 4, not 0 and 1 (the verifier's finding).
func test_a_gapped_line_up_keeps_each_seats_colour() -> void:
	app.show_join()
	for device: int in [50, 51, 52, 55, 56]:
		S.tap(app, device, JOY_BUTTON_A)
	for device: int in [51, 52, 55]:
		S.tap(app, device, JOY_BUTTON_B)
	S.frame(app, 0)
	seats.set_bots(0)
	S.tap(app, 50, JOY_BUTTON_START)
	S.frame(app, 0)
	var race: Node = app.current_screen()
	assert_eq(S.screen_name(app), "Versus")
	assert_eq(race.lineup, [0, 4] as Array[int])
	assert_eq(race.cars.seat_colours, [0, 4] as Array[int])
	assert_eq(race.hud.lineup, [0, 4] as Array[int])
	var cars: Array[Car] = race.game_match.world.players
	assert_eq(cars.size(), 2)
	var second := Cars.seat_car_sprite(cars[1], race.lineup)
	assert_eq(second["frame"], PlayerColours.frame_name("car_red", 4), "slot 1 is drawn in seat 4's colour")
	assert_ne(second["frame"], PlayerColours.frame_name("car_red", 1), "not in seat 1's")
	var pads: Array[bool] = race.pads_here()
	var info := VersusHud.seat_info(race.game_match, race.lineup, pads, 1)
	assert_eq(info["seat"], 4)
	assert_eq(info["name"], "P5")
	# A round won by the second slot: the results name seat 4, not seat 1.
	SimHelpers.arrive(race.game_match.world, 1)
	S.frame(app, 3)
	assert_eq(race.game_match.phase, Match.ROUND_OVER)
	var titles := _texts(VersusHud.overlay_for(race.game_match, race.lineup))
	assert_true(" ".join(titles).contains("P5"), "the results show P5: %s" % [titles])
	assert_false(" ".join(titles).contains("P2"), "and no P2: %s" % [titles])


## Each slot's byte: its pad's held controls with the single-player mapping, and 0xFF for a bot, whose bot drives.
func test_each_seat_gets_its_pads_byte_and_the_bot_drives_its_own() -> void:
	var race := _race([50, 51], 1)
	S.pad(app, 50, JOY_BUTTON_A, true)
	S.pad(app, 51, JOY_BUTTON_DPAD_LEFT, true)
	assert_eq(seats.step_bytes(3), PackedByteArray([
		Held.to_byte(Held.ACCEL | Held.NITRO, PlayerInput.CONFIRM), Held.to_byte(Held.LEFT), PlayerInput.BOT
	]), "A held is nitro and throttle, and its press a confirm")
	S.pad(app, 51, JOY_BUTTON_DPAD_LEFT, false)
	S.frame(app, 90)
	var world: World = race.world
	assert_eq(world.players[0].gear, Car.GEAR_NITRO, "A held: nitro")
	assert_gt(world.players[0].speed, 0.0)
	assert_eq(world.players[1].speed, 0.0, "nothing held: no throttle")
	assert_gt(world.players[2].speed, 0.0, "the bot drives")


## Any person's Start pauses, any person's resumes (the world's rule); a pad that holds no seat cannot.
func test_any_person_pauses_and_resumes() -> void:
	var race := _race([50, 51, 52], 0)
	var world: World = race.world
	S.frame(app, 10)
	S.tap(app, 55, JOY_BUTTON_START)
	S.frame(app, 1)
	assert_eq(world.phase, World.RUNNING, "a pad that holds no seat")
	S.tap(app, 52, JOY_BUTTON_START)
	S.frame(app, 1)
	assert_eq(world.phase, World.PAUSED, "P3's Start")
	assert_eq(VersusHud.overlay_for(race.game_match, race.lineup)["title"], "PAUSED")
	var tick := world.stage_ticks
	S.frame(app, 30)
	assert_eq(world.stage_ticks, tick, "nothing runs while paused")
	S.tap(app, 50, JOY_BUTTON_START)
	S.frame(app, 1)
	assert_eq(world.phase, World.RUNNING, "P1's Start resumes")
	assert_eq(VersusHud.overlay_for(race.game_match, race.lineup), {})


## While paused, a seated pad's Back (Select) or Esc goes to the title, which lets every pad go. While running, Back
## and Esc do nothing (so Esc twice cannot lose the match: Esc is no pause key while pads are here).
func test_back_or_esc_while_paused_quits_to_the_title() -> void:
	var race := _race([50, 51], 0)
	var world: World = race.world
	S.tap(app, 51, JOY_BUTTON_BACK)
	S.frame(app, 1)
	assert_eq([S.screen_name(app), world.phase], ["Versus", World.RUNNING], "Back while running")
	S.tap(app, 51, JOY_BUTTON_START)
	S.frame(app, 1)
	assert_eq(world.phase, World.PAUSED)
	S.tap(app, 55, JOY_BUTTON_BACK)
	S.frame(app, 1)
	assert_eq(S.screen_name(app), "Versus", "a pad that holds no seat")
	S.tap(app, 51, JOY_BUTTON_BACK)
	S.frame(app, 1)
	assert_eq(S.screen_name(app), "Title")
	assert_eq(seats.people(), 0)
	assert_false(seats.locked)
	assert_eq(app.input, app.solo)
	race = _race([50, 51], 0)
	world = race.world
	S.key_tap(app, KEY_ESCAPE)
	S.frame(app, 1)
	assert_eq([S.screen_name(app), world.phase], ["Versus", World.RUNNING], "Esc while running, with pads here")
	S.key_tap(app, KEY_ESCAPE)
	S.frame(app, 1)
	assert_eq([S.screen_name(app), world.phase], ["Versus", World.RUNNING], "Esc twice")
	S.tap(app, 50, JOY_BUTTON_START)
	S.frame(app, 1)
	assert_eq(world.phase, World.PAUSED)
	S.key_tap(app, KEY_ESCAPE)
	S.frame(app, 1)
	assert_eq(S.screen_name(app), "Title", "Esc while paused")


## With every person's pad gone, the keyboard is the only way out: Esc pauses a running round, and Esc while paused
## goes to the title. Between rounds Esc goes to the title too: no pad is left to confirm the next round (0xFF never
## confirms), so the panel would wait for good.
func test_with_every_pad_gone_esc_pauses_and_leaves() -> void:
	var race := _race([50, 51], 0)
	var world: World = race.world
	S.frame(app, 10)
	Input.joy_connection_changed.emit(50, false)
	S.key_tap(app, KEY_ESCAPE)
	S.frame(app, 1)
	assert_eq(world.phase, World.RUNNING, "one pad is still here: Esc does nothing")
	Input.joy_connection_changed.emit(51, false)
	assert_eq(seats.pad_count(), 0)
	S.key_tap(app, KEY_ESCAPE)
	S.frame(app, 1)
	assert_eq(world.phase, World.PAUSED, "no pad left: Esc pauses")
	S.key_tap(app, KEY_ESCAPE)
	S.frame(app, 1)
	assert_eq(S.screen_name(app), "Title", "and Esc while paused leaves")
	race = _race([50, 51], 0)
	var m: Match = race.game_match
	S.frame(app, 10)
	Input.joy_connection_changed.emit(50, false)
	Input.joy_connection_changed.emit(51, false)
	SimHelpers.arrive(m.world, 1)
	S.frame(app, 1)
	assert_eq(m.phase, Match.ROUND_OVER)
	S.frame(app, Config.MATCH_CONFIRM_TICKS + 60)
	assert_eq(m.phase, Match.ROUND_OVER, "nobody can confirm the next round")
	S.key_tap(app, KEY_ENTER)
	S.frame(app, 1)
	assert_eq(m.phase, Match.ROUND_OVER, "nor can the keyboard")
	S.key_tap(app, KEY_ESCAPE)
	S.frame(app, 1)
	assert_eq(S.screen_name(app), "Title", "Esc between rounds leaves")
	assert_eq(seats.people(), 0)


## Versus is pads only (docs/DECISIONES_MULTIJUGADOR.md §2): the keyboard drives no car. Keys held (X, Up, Z, Left)
## give no seat any input, and key presses (P, Enter, Space) neither pause a running round nor start the next one.
func test_the_keyboard_drives_no_car() -> void:
	var race := _race([50, 51], 1)
	var m: Match = race.game_match
	var world: World = race.world
	for code: Key in KEYS_HELD:
		S.key(app, code, true)
	var xs: Array[float] = [world.players[0].x, world.players[1].x]
	assert_eq(seats.step_bytes(3), PackedByteArray([PlayerInput.NONE, PlayerInput.NONE, PlayerInput.BOT]),
		"keys held: each person's slot has its idle pad's byte")
	S.frame(app, 60)
	for slot in 2:
		var car: Car = world.players[slot]
		assert_eq([car.gear, car.speed, car.x], [Car.GEAR_LOW, 0.0, xs[slot]], "slot %d: no nitro, no throttle, no steering" % slot)
	assert_gt(world.players[2].speed, 0.0, "the bot drives")
	for code: Key in [KEY_P, KEY_ENTER, KEY_SPACE, KEY_KP_ENTER]:
		S.key_tap(app, code)
		S.frame(app, 1)
		assert_eq(world.phase, World.RUNNING, "%s does not pause" % OS.get_keycode_string(code))
	for code: Key in KEYS_HELD:
		S.key(app, code, false)
	SimHelpers.arrive(m.world, 1)
	S.frame(app, 1)
	assert_eq(m.phase, Match.ROUND_OVER)
	S.frame(app, Config.MATCH_CONFIRM_TICKS)
	for code: Key in [KEY_ENTER, KEY_SPACE, KEY_KP_ENTER, KEY_P]:
		S.key_tap(app, code)
		S.frame(app, 1)
		assert_eq(m.phase, Match.ROUND_OVER, "%s does not start round 2" % OS.get_keycode_string(code))
	S.tap(app, 51, JOY_BUTTON_A)
	S.frame(app, 1)
	assert_eq([m.phase, m.round_number], [Match.PLAYING, 2], "a pad's A does")


## NOTIFICATION_APPLICATION_FOCUS_OUT pauses a running round on its next step, and does nothing to a paused one.
func test_losing_focus_pauses_a_running_round() -> void:
	var race := _race([50, 51], 1)
	var world: World = race.world
	S.frame(app, 5)
	app.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	assert_eq(world.phase, World.RUNNING, "nothing until a step")
	S.frame(app, 0)
	assert_eq(world.phase, World.RUNNING, "a frame with no step keeps the press")
	S.frame(app, 1)
	assert_eq(world.phase, World.PAUSED)
	app.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	S.frame(app, 1)
	assert_eq(world.phase, World.PAUSED, "a second focus loss does not resume")
	app.notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
	S.frame(app, 1)
	assert_eq(world.phase, World.PAUSED, "nor does getting focus back")


## A round played to its end through the screen; the results wait, a confirm before MATCH_CONFIRM_TICKS steps does
## not count, one from then on starts round 2. The panel shows PRESS A only once it counts.
func test_a_round_ends_and_a_after_the_delay_starts_round_2() -> void:
	var race := _race([50, 51], 0)
	var m: Match = race.game_match
	S.frame(app, 20)
	SimHelpers.arrive(m.world, 1)
	S.frame(app, 1)
	assert_eq(m.phase, Match.ROUND_OVER)
	assert_eq(m.last_round_winner(), 1, "P2 is the person left")
	assert_eq(m.phase_ticks, 0)
	var overlay := VersusHud.overlay_for(m, race.lineup)
	assert_eq(overlay["title"], "RACE 1 OF 3")
	assert_has(_texts(overlay), "P2 WINS THE RACE")
	assert_has(_texts(overlay), "P2 1ST +10 10", "the winner's place and points")
	assert_eq(_texts(overlay).back(), "", "no PRESS A yet")
	S.frame(app, Config.MATCH_CONFIRM_TICKS - 2)
	S.tap(app, 51, JOY_BUTTON_A)
	S.frame(app, 1)
	assert_eq(m.phase, Match.ROUND_OVER, "A at step %d does not count" % (Config.MATCH_CONFIRM_TICKS - 1))
	assert_eq(_texts(VersusHud.overlay_for(m, race.lineup)).back(), "", "no PRESS A yet")
	S.frame(app, 1)
	assert_eq(m.phase, Match.ROUND_OVER, "the results wait for a press")
	assert_eq(_texts(VersusHud.overlay_for(m, race.lineup)).back(), "PRESS A", "from now on it counts")
	S.tap(app, 51, JOY_BUTTON_A)
	S.frame(app, 1)
	assert_eq(m.phase, Match.PLAYING)
	assert_eq(m.round_number, 2)
	assert_eq(m.wins, [0, 1] as Array[int])
	assert_eq(m.world.phase, World.RUNNING)
	assert_eq(m.world.players[0].alive, 1, "everybody is back")
	assert_eq(race.game_match, m, "the same match goes on")


## The match ends; A and B wait MATCH_CONFIRM_TICKS steps; then A plays a rematch with the next seed and the same
## seats.
func test_the_match_ends_and_a_plays_a_rematch_on_the_same_seats() -> void:
	var race := _race([50, 51], 1)
	var m := _play_to_match_over(race)
	assert_eq(m.winner, 1)
	var overlay := VersusHud.overlay_for(m, race.lineup)
	assert_eq(overlay["title"], "MATCH OVER")
	assert_eq(_texts(overlay)[0], "P2 WINS THE MATCH")
	S.frame(app, Config.MATCH_CONFIRM_TICKS - 1)
	S.tap(app, 50, JOY_BUTTON_A)
	S.tap(app, 50, JOY_BUTTON_B)
	S.frame(app, 1)
	assert_eq([S.screen_name(app), race.game_match], ["Versus", m], "too early for A or B")
	assert_eq(_texts(VersusHud.overlay_for(m, race.lineup)).back(), "A  REMATCH    B  JOIN SCREEN")
	S.tap(app, 50, JOY_BUTTON_A)
	S.frame(app, 1)
	var again: Match = race.game_match
	assert_ne(again, m, "a new match")
	assert_eq(again.world.game_seed, m.world.game_seed + 1, "the next seed")
	assert_eq(race.lineup, [0, 1, 2] as Array[int], "the same seats")
	assert_eq(again.human_seats(), [0, 1] as Array[int])
	assert_eq([again.phase, again.round_number, again.wins], [Match.PLAYING, 1, [0, 0, 0]])
	assert_eq(race.matches, 2)
	S.frame(app, 1)
	assert_eq(again.world.tick, 1, "the rematch runs")


## B (or Back, or Esc) at the match's end goes back to the join screen, with the same pads on their seats and the
## bots still chosen.
func test_the_match_ends_and_b_goes_back_to_the_join_screen() -> void:
	var race := _race([50, 51], 2)
	_play_to_match_over(race)
	S.frame(app, Config.MATCH_CONFIRM_TICKS)
	S.tap(app, 51, JOY_BUTTON_B)
	S.frame(app, 1)
	assert_eq(S.screen_name(app), "Join")
	assert_false(seats.locked)
	assert_eq([seats.seat_of(50), seats.seat_of(51), seats.bots], [0, 1, 2])
	S.tap(app, 50, JOY_BUTTON_START)
	S.frame(app, 0)
	assert_eq(S.screen_name(app), "Versus", "and they can race again")
	_play_to_match_over(app.current_screen())
	S.frame(app, Config.MATCH_CONFIRM_TICKS)
	S.key_tap(app, KEY_ESCAPE)
	S.frame(app, 1)
	assert_eq(S.screen_name(app), "Join", "Esc too")


## One person against a bot: the bot wins all three races, so it wins the match (a bot can win it), and the
## panel names it. With nobody winning a race match, the panel says DRAW.
func test_a_bot_that_wins_the_three_races_wins_the_match() -> void:
	var race := _race([50], 1)
	var m: Match = race.game_match
	for round_index in 3:
		S.frame(app, 5)
		SimHelpers.arrive(m.world, 1)
		S.frame(app, 1)
		if m.phase == Match.ROUND_OVER:
			S.frame(app, Config.MATCH_CONFIRM_TICKS)
			S.tap(app, 50, JOY_BUTTON_A)
			S.frame(app, 1)
	assert_eq(m.phase, Match.MATCH_OVER)
	assert_eq(m.winner, 1, "the bot won every race")
	assert_eq(_texts(VersusHud.overlay_for(m, race.lineup))[0], "BOT WINS THE MATCH")
	m.winner = Match.NO_WINNER
	assert_eq(_texts(VersusHud.overlay_for(m, race.lineup))[0], "DRAW", "nobody won a race match: a draw")


## A pad that goes away: its seat's byte is 0xFF at once and the round goes on, its bot driving; the HUD says NO PAD.
## The same pad (GUID) coming back takes its seat; a pad that holds no seat takes the lowest orphan seat with A.
func test_a_pad_that_goes_away_and_comes_back() -> void:
	guids = {50: "first", 51: "second", 57: "second"}
	var race := _race([50, 51], 0)
	var world: World = race.world
	S.pad(app, 51, JOY_BUTTON_A, true)
	S.frame(app, 30)
	Input.joy_connection_changed.emit(51, false)
	S.frame(app, 1)
	assert_true(seats.is_orphan(1))
	assert_eq(world.phase, World.RUNNING, "the round goes on")
	assert_eq(seats.step_bytes(2)[1], PlayerInput.BOT)
	assert_eq(race.pads_here(), [true, false] as Array[bool])
	var info := VersusHud.seat_info(race.game_match, race.lineup, race.pads_here(), 1)
	assert_true(info["no_pad"])
	assert_eq(world.players[1].human, 1, "still a person's seat")
	var y := world.players[1].y_world
	S.frame(app, 60)
	assert_gt(world.players[1].y_world, y, "its bot drives")
	Input.joy_connection_changed.emit(56, true)
	assert_true(seats.is_orphan(1), "another pad does not take it by connecting")
	Input.joy_connection_changed.emit(57, true)
	assert_eq(seats.seat_of(57), 1, "the same GUID takes it back")
	assert_eq(race.pads_here(), [true, true] as Array[bool])
	Input.joy_connection_changed.emit(57, false)
	S.tap(app, 50, JOY_BUTTON_A)
	S.frame(app, 1)
	assert_true(seats.is_orphan(1), "A on a seated pad claims nothing")
	S.tap(app, 58, JOY_BUTTON_A)
	S.frame(app, 1)
	assert_eq(seats.seat_of(58), 1, "A on a pad that holds no seat takes the orphan seat")
	assert_false(seats.is_orphan(1))


## The HUD: a panel per seat, seats 0 to 2 down the left column and 3 to 5 down the right, inside the side panels;
## the name (P1 to P6, or BOT), wins, points, fuel and the marks.
func test_the_hud_shows_every_seat_in_its_place() -> void:
	for seat in Seats.SEATS:
		var r := VersusHud.seat_panel_rect(seat)
		var column := ViewConfig.PANEL_LEFT if seat < 3 else ViewConfig.PANEL_RIGHT
		assert_true(column.encloses(r), "seat %d's panel in its column" % seat)
		if seat % 3 > 0:
			assert_false(r.intersects(VersusHud.seat_panel_rect(seat - 1)))
	var m := Match.create(Config.standard(), 3, 3, 0b011)
	var lineup: Array[int] = [1, 2, 4]
	var w := m.world
	w.players[0].alive = 0
	w.players[1].touching_edge = 1
	w.players[2].fuel = 10.0
	m.wins[1] = 1
	var pads: Array[bool] = [true, false, true]
	var infos: Array = []
	for slot in 3:
		infos.append(VersusHud.seat_info(m, lineup, pads, slot))
	assert_eq([infos[0]["seat"], infos[1]["seat"], infos[2]["seat"]], [1, 2, 4])
	assert_eq([infos[0]["name"], infos[1]["name"], infos[2]["name"]], ["P2", "P3", "BOT"])
	assert_eq([VersusHud.mark_of(infos[0]), VersusHud.mark_of(infos[1]), VersusHud.mark_of(infos[2])],
		["OUT", "EDGE", "LOW FUEL"])
	assert_eq([infos[0]["no_pad"], infos[1]["no_pad"], infos[2]["no_pad"]], [false, true, false])
	assert_eq(infos[1]["wins"], 1)


## The results panels: a row per seat, in seat order, each with its seat's badge; the table and every line fit their
## panel, which fits the screen and stays clear of the seat panels.
func test_the_results_panels_list_every_seat_in_its_colour() -> void:
	var m := Match.create(Config.standard(), 3, 6, 0b111111)
	var lineup: Array[int] = [0, 1, 2, 3, 4, 5]
	m.world.players[3].score = 999999
	m.world.players[3].distance = 999999.0
	m.world.players[2].alive = 0
	m.wins[4] = 1
	m.phase = Match.ROUND_OVER
	m.round_number = 5
	m.phase_ticks = Config.MATCH_CONFIRM_TICKS
	var font := app.atlas.font
	var table_w: int = VersusHud.COLUMN_X.back() + VersusHud.COLUMN_W.back()
	for overlay: Dictionary in [VersusHud.overlay_for(m, lineup), _match_over(m, lineup)]:
		var width: int = overlay["width"]
		var inner := width - 2 * ViewConfig.OVERLAY_PADDING
		assert_lt(table_w, inner + 1, "the table fits")
		var seats: Array[int] = []
		for line: Dictionary in overlay["lines"]:
			var text := VersusHud.line_text(line)
			match int(line["kind"]):
				VersusHud.ROW:
					seats.append(line["seat"])
					assert_eq(line["name"], PlayerColours.label(line["seat"], true), text)
					for i in (line["cells"] as Array).size():
						var cell: String = line["cells"][i]
						assert_lt(Draw.text_width(font, cell, ViewConfig.TEXT_SMALL), VersusHud.COLUMN_W[i] + 1, cell)
				VersusHud.WINNER:
					assert_lt(VersusHud.BADGE_W + Draw.text_width(font, " " + str(line["text"]), ViewConfig.TEXT_SMALL), inner + 1, text)
				_:
					assert_lt(Draw.text_width(font, text, ViewConfig.TEXT_SMALL), inner + 1, text)
		assert_eq(seats, lineup, "%s: a row per seat, in seat order" % overlay["title"])
		var r := VersusHud.panel_rect(overlay)
		assert_true(Rect2i(0, 0, ViewConfig.VIEW_W, ViewConfig.VIEW_H).encloses(r))
		assert_false(r.intersects(ViewConfig.PANEL_LEFT) or r.intersects(ViewConfig.PANEL_RIGHT), "clear of the HUD")
	var round_rows := VersusHud.texts(VersusHud.overlay_for(m, lineup))
	assert_has(round_rows, "P3 000000 000000 OUT", "the round's points, distance and OUT")
	assert_has(round_rows, "P4 999999 999999", "six digits each")
	for name: String in ["P1", "P2", "P3", "P4", "P5", "P6"]:
		var count := 0
		for text: String in round_rows:
			if text.begins_with(name + " "):
				count += 1
		assert_eq(count, 1, "one row for %s" % name)


## The self test's versus leg (App.selftest_versus_problems(), which --selftest and tools/export_check.sh run) passes
## in process and ends on the title with every pad let go.
func test_the_self_tests_versus_leg_passes() -> void:
	seats.guid_of = Seats.engine_guid
	assert_eq(app.selftest_versus_problems(), PackedStringArray())
	assert_eq(S.screen_name(app), "Title")
	assert_eq(seats.people(), 0)


## A race's seat panel names the place now and the race points over the match; a car across the line is finished, not out.
func test_a_race_panel_shows_the_place_and_the_match_points() -> void:
	var race := _race([50, 51], 1)
	var m: Match = race.game_match
	var lineup: Array[int] = race.lineup
	var pads: Array[bool] = [true, true, true]
	m.world.players[2].y_world = 500.0
	m.world.players[1].y_world = 300.0
	m.race_points[1] = 17
	var info := VersusHud.seat_info(m, lineup, pads, 1)
	assert_eq([info["place"], info["points"], info["finished"], info["out"]], [2, 17, false, false])
	assert_eq(VersusHud.seat_info(m, lineup, pads, 2)["place"], 1)
	m.world.players[1].speed = 212.4
	assert_eq(VersusHud.seat_info(m, lineup, pads, 1)["speed"], 212, "the speed, rounded")
	m.world.players[2].finish_place = 1
	m.world.players[2].alive = 0
	info = VersusHud.seat_info(m, lineup, pads, 2)
	assert_eq([info["finished"], info["out"], VersusHud.mark_of(info)], [true, false, "FINISHED"])
	assert_eq(info["speed"], 0, "a car across the line has stopped")
	assert_eq([VersusHud.ordinal(1), VersusHud.ordinal(2), VersusHud.ordinal(3), VersusHud.ordinal(4)], ["1ST", "2ND", "3RD", "4TH"])


## A match of three races: each race's panel lists the places and points; the match's lists the places over the races and
## the ranking change of each person (not the bot's), which the session's ranking keeps.
func test_a_race_match_scores_the_places_and_moves_the_ranking() -> void:
	var race := _race([50, 51], 1)
	var m: Match = race.game_match
	for race_index in 3:
		S.frame(app, 5)
		SimHelpers.arrive(m.world, 1)
		S.frame(app, 1)
		if race_index < 2:
			assert_eq(m.phase, Match.ROUND_OVER)
			assert_has(_texts(VersusHud.overlay_for(m, race.lineup)), "P2 1ST +10 %d" % (10 * (race_index + 1)))
			assert_has(_texts(VersusHud.overlay_for(m, race.lineup)), "P1 2ND +7 %d" % (7 * (race_index + 1)))
			assert_eq(app.ranking.record("seat:1")["matches"], 0, "the ranking moves when the match ends")
			S.frame(app, Config.MATCH_CONFIRM_TICKS)
			S.tap(app, 50, JOY_BUTTON_A)
			S.frame(app, 1)
	assert_eq(m.phase, Match.MATCH_OVER)
	assert_eq(m.race_points, [21, 30, 15] as Array[int])
	assert_eq(race.ranking_results.size(), 2, "the two people, not the bot")
	assert_eq(race.ranking_results[1], {"before": 0, "after": 25, "delta": 25, "name": "P2"})
	assert_eq(race.ranking_results[0], {"before": 0, "after": 0, "delta": 0, "name": "P1"}, "second of three stays level")
	assert_eq(app.ranking.record("seat:1")["points"], 25)
	assert_eq(app.ranking.record("seat:2")["matches"], 0, "bots have no ranking")
	S.frame(app, 1)
	var texts := _texts(VersusHud.overlay_for(m, race.lineup, false, race.ranking_results))
	assert_eq(texts[0], "P2 WINS THE MATCH")
	assert_has(texts, "P2 1ST 1-1-1 30")
	assert_has(texts, "P2 +25 25 BRONZE")
	assert_has(texts, "P1 +0 0 BRONZE")
	# A rematch is a new match: it settles again, and the totals carry on.
	S.frame(app, Config.MATCH_CONFIRM_TICKS)
	S.tap(app, 50, JOY_BUTTON_A)
	S.frame(app, 1)
	assert_eq(race.ranking_results, {}, "nothing settled yet")
	assert_eq(app.ranking.record("seat:1")["points"], 25)


## Leaving a match that is not over (quit from the pause) counts for the people in it as the last places.
func test_leaving_a_match_midway_ranks_the_people_last() -> void:
	var race := _race([50, 51], 1)
	var m: Match = race.game_match
	S.frame(app, 5)
	S.tap(app, 50, JOY_BUTTON_START)
	S.frame(app, 1)
	assert_eq(race.world.phase, World.PAUSED)
	S.tap(app, 51, JOY_BUTTON_BACK)
	S.frame(app, 1)
	assert_eq(S.screen_name(app), "Title")
	assert_eq(m.abandoned_mask, 0b011, "both people left; the bot cannot")
	assert_eq(app.ranking.record("seat:0")["matches"], 1)
	assert_eq(app.ranking.record("seat:1")["matches"], 1)
	assert_eq(app.ranking.record("seat:2")["matches"], 0)


## A person whose pad goes away mid-match has left: their seat's bot drives on and they rank last.
func test_a_pad_that_goes_away_leaves_the_match() -> void:
	var race := _race([50, 51], 1)
	var m: Match = race.game_match
	S.frame(app, 5)
	Input.joy_connection_changed.emit(51, false)
	S.frame(app, 2)
	assert_eq(m.abandoned_mask, 0b010)


## The race tower (left column) follows the live order: a car that passes another takes its row, which slides there and
## flashes; a car across the line stays in front of every car still racing.
func test_the_race_tower_follows_the_order_and_its_rows_slide() -> void:
	var race := _race([50, 51], 1)
	var hud: VersusHud = race.hud
	var w: World = race.world
	w.players[0].y_world = 900.0
	w.players[1].y_world = 500.0
	w.players[2].y_world = 100.0
	race.render()
	hud.animate(0.0)
	assert_eq(w.standings(), [0, 1, 2] as Array[int])
	assert_eq(hud._row_y[0], VersusHud.tower_row_y(0))
	assert_eq(hud._row_y[2], VersusHud.tower_row_y(2))
	w.players[2].y_world = 700.0
	race.render()
	assert_true(hud.flashing(2) or hud._flash.has(2), "the car that passed flashes")
	assert_false(hud._flash.has(0))
	hud.animate(1.0 / 60.0)
	var middle: float = hud._row_y[2]
	assert_lt(middle, VersusHud.tower_row_y(2), "it moves up")
	assert_gt(middle, VersusHud.tower_row_y(1), "but has not got there yet")
	for i in 60:
		hud.animate(1.0 / 60.0)
	assert_eq(hud._row_y[2], VersusHud.tower_row_y(1), "it arrives")
	assert_eq(hud._row_y[1], VersusHud.tower_row_y(2), "and the car it passed went down")
	assert_eq(hud._flash[2], 0.0, "the flash ran down")
	w.players[0].finish_place = 1
	w.players[0].alive = 0
	w.players[0].y_world = 100.0
	assert_eq(w.standings()[0], 0, "across the line beats every car still racing")


func test_the_tower_fits_the_left_column_with_six_cars() -> void:
	var last := VersusHud.tower_row_y(5) + VersusHud.ROW_H
	assert_lt(last, float(ViewConfig.PANEL_LEFT.end.y) + 1.0, "six rows inside the column")
	assert_lt(VersusHud.NITRO_Y + VersusHud.SEG_H, VersusHud.POINTS_Y, "the gauge is above the points")
	assert_lt(VersusHud.POINTS_Y + ViewConfig.TEXT_SMALL, VersusHud.ROW_H - VersusHud.BORDER + 1, "the points are inside the row")
	var seg_w := VersusHud.SEGMENTS * VersusHud.SEG_W + (VersusHud.SEGMENTS - 1) * VersusHud.SEG_GAP
	assert_lt(VersusHud.LABEL_DX + seg_w, ViewConfig.PANEL_LEFT.size.x - VersusHud.BORDER + 1, "the gauge fits the row")
	assert_lt(VersusHud.LABEL_DX + Draw.text_width(app.atlas.font, "WWWWWWWW", ViewConfig.TEXT_SMALL), ViewConfig.PANEL_LEFT.size.x - VersusHud.BORDER + 1, "the widest name")
	assert_lt(VersusHud.LABEL_DX + Draw.text_width(app.atlas.font, "400 KMH", ViewConfig.TEXT_SMALL), ViewConfig.PANEL_LEFT.size.x)


# --- helpers ---------------------------------------------------------------------------------------------------------


## The join screen with these pads seated (in this order) and this many bots, then Start from the first pad: the race
## screen.
func _race(pads: Array[int], bots: int) -> Node:
	app.show_join()
	for device: int in pads:
		S.tap(app, device, JOY_BUTTON_A)
	S.frame(app, 0)
	seats.set_bots(bots)
	S.tap(app, pads[0], JOY_BUTTON_START)
	S.frame(app, 0)
	assert_eq(S.screen_name(app), "Versus", "the race opened")
	return app.current_screen()


## Plays the race's match to its end through the screen: seat 0 (P1, pad 50) runs dry each round, so P2 wins the
## rounds when it is a person, and pad 50 confirms each next round. Returns the match.
func _play_to_match_over(race: Node) -> Match:
	var m: Match = race.game_match
	for round_index in Config.MATCH_ROUNDS_MAX:
		if m.phase == Match.MATCH_OVER:
			break
		S.frame(app, 5)
		SimHelpers.arrive(m.world, 1)
		S.frame(app, 1)
		if m.phase == Match.ROUND_OVER:
			S.frame(app, Config.MATCH_CONFIRM_TICKS)
			S.tap(app, 50, JOY_BUTTON_A)
			S.frame(app, 1)
	assert_eq(m.phase, Match.MATCH_OVER, "the match ended")
	return m


## The texts of an overlay's lines.
static func _texts(overlay: Dictionary) -> Array:
	return VersusHud.texts(overlay)


static func _match_over(m: Match, lineup: Array[int]) -> Dictionary:
	var over := m.clone()
	over.phase = Match.MATCH_OVER
	over.winner = 3
	return VersusHud.overlay_for(over, lineup)
