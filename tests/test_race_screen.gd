extends "res://tests/test_case.gd"
## The versus race screen (B2, scripts/app/versus.gd) through a real App and synthetic joypad events
## (tests/screen_helpers.gd): a Match of the join screen's line-up, one byte per seat (the pad's, or 0xFF for a bot and
## for a pad that has gone), pause by any person and quit to the title, the pause on focus loss, a round played to its
## end and the confirm that counts only after Config.MATCH_CONFIRM_TICKS, the match's end with a rematch (the next
## seed, the same seats) or the join screen, pads going away and coming back, and what the HUD shows.

const S := preload("res://tests/screen_helpers.gd")
const App := preload("res://scripts/app/app.gd")
const Seats := preload("res://scripts/input/seats.gd")
const Config := preload("res://scripts/sim/config.gd")
const World := preload("res://scripts/sim/world.gd")
const Match := preload("res://scripts/sim/match.gd")
const Car := preload("res://scripts/sim/car.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")
const Held := preload("res://scripts/input/held.gd")
const VersusHud := preload("res://scripts/view/versus_hud.gd")
const PlayerColours := preload("res://scripts/view/player_colours.gd")
const ViewConfig := preload("res://scripts/view/view_config.gd")
const Draw := preload("res://scripts/view/draw.gd")
const Hud := preload("res://scripts/view/hud.gd")

const SEED := 11
const PADS: Array[int] = [50, 51, 52, 55, 56, 57, 58]

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
	assert_eq(app.input, seats)
	S.frame(app, 3)
	assert_eq(m.world.tick, 3, "the clock's steps")


## Each slot's byte: its pad's held controls with the single-player mapping, and 0xFF for a bot, whose bot drives.
func test_each_seat_gets_its_pads_byte_and_the_bot_drives_its_own() -> void:
	var race := _race([50, 51], 1)
	S.pad(app, 50, JOY_BUTTON_A, true)
	S.pad(app, 51, JOY_BUTTON_DPAD_LEFT, true)
	assert_eq(seats.step_bytes(3), PackedByteArray([
		Held.to_byte(Held.ACCEL | Held.HIGH_GEAR, PlayerInput.CONFIRM), Held.to_byte(Held.LEFT), PlayerInput.BOT
	]), "A held is high gear and throttle, and its press a confirm")
	S.pad(app, 51, JOY_BUTTON_DPAD_LEFT, false)
	S.frame(app, 90)
	var world: World = race.world
	assert_eq(world.players[0].gear, Car.GEAR_HIGH, "A held: high gear")
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
## does nothing and Esc pauses.
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
	assert_eq(world.phase, World.PAUSED, "Esc pauses a running round")
	S.key_tap(app, KEY_ESCAPE)
	S.frame(app, 1)
	assert_eq(S.screen_name(app), "Title", "Esc while paused")


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
	m.world.players[0].fuel = 0.01
	S.frame(app, 1)
	assert_eq(m.phase, Match.ROUND_OVER)
	assert_eq(m.last_round_winner(), 1, "P2 is the person left")
	assert_eq(m.phase_ticks, 0)
	var overlay := VersusHud.overlay_for(m, race.lineup)
	assert_eq(overlay["title"], "ROUND 1 OVER")
	assert_has(_texts(overlay), "P2 WINS THE ROUND")
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


## One person against bots: two rounds not won end the match with nobody winning it: YOU LOSE.
func test_one_person_who_loses_the_match_reads_you_lose() -> void:
	var race := _race([50], 1)
	var m: Match = race.game_match
	for round_index in 2:
		S.frame(app, 5)
		m.world.players[0].fuel = 0.01
		S.frame(app, 1)
		if m.phase == Match.ROUND_OVER:
			S.frame(app, Config.MATCH_CONFIRM_TICKS)
			S.tap(app, 50, JOY_BUTTON_A)
			S.frame(app, 1)
	assert_eq(m.phase, Match.MATCH_OVER)
	assert_eq(m.winner, Match.NO_WINNER)
	assert_eq(_texts(VersusHud.overlay_for(m, race.lineup))[0], "YOU LOSE")
	m.world.players[1].human = 1
	assert_eq(_texts(VersusHud.overlay_for(m, race.lineup))[0], "DRAW", "several people and nobody won: a draw")


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
		m.world.players[0].fuel = 0.01
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
