extends Node2D
## The versus race screen (B2; docs/GODOT_PLAN.md §5, §7): a Match (scripts/sim/match.gd) of the join screen's
## line-up, stepped by the app's fixed step, drawn by road.gd, cars.gd (each car in its seat's colour) and
## versus_hud.gd (a panel per seat, and the pause, round and match panels).
##
## - Steps. Each frame runs the clock's steps, each with seats.step_bytes(): a person's seat gets its pad's byte, a
##   bot's seat and an orphan seat (its pad has gone) get 0xFF, so their bot drives. The match runs the rounds on
##   those bytes: pause and resume are the world's (any person's Start); after a round, a person's A (or Start) from
##   Config.MATCH_CONFIRM_TICKS steps on starts the next one.
## - Menu commands (scripts/input/nav.gd), taken before the steps:
##   - while the round is paused, a seated pad's Back (Select), or Esc on the keyboard, goes to the title;
##   - between rounds (the round-over panel), Esc on the keyboard goes to the title too, so the keyboard can leave a
##     match whose pads have all gone (their bots never confirm the next round);
##   - while a round runs, the keyboard does nothing (versus is pads only, and Esc quits once paused, so Esc must not
##     pause too: Esc twice would lose the match), but for one case: when no person's pad is left, Esc pauses (a press
##     of the program, on the next step), as the keyboard is then the only way to stop the race;
##   - once the match is over, from MATCH_CONFIRM_TICKS steps on (so a press made while racing cannot skip the
##     panel), a seated pad's A or Start plays a rematch (the same seats, the next seed: App.next_seed()) and its B or
##     Back, or Esc, goes back to the join screen with the same pads on their seats;
##   - a pad that holds no seat and presses A takes an orphan seat (seats.gd claim(): the lowest one).
## - A pad that goes away orphans its seat at once (seats.gd, from Input.joy_connection_changed) and the round goes on;
##   the same pad (by GUID) coming back takes its seat again.
## - Losing focus while a round runs pauses it (a press of the program on the next step).

const App := preload("res://scripts/app/app.gd")
const Config := preload("res://scripts/sim/config.gd")
const World := preload("res://scripts/sim/world.gd")
const Car := preload("res://scripts/sim/car.gd")
const Match := preload("res://scripts/sim/match.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")
const Nav := preload("res://scripts/input/nav.gd")
const Seats := preload("res://scripts/input/seats.gd")
const Ranking := preload("res://scripts/sim/ranking.gd")
const PlayerColours := preload("res://scripts/view/player_colours.gd")
const Road := preload("res://scripts/view/road.gd")
const Cars := preload("res://scripts/view/cars.gd")
const VersusHud := preload("res://scripts/view/versus_hud.gd")

var app: App
var cfg: Config = Config.game()
var seats: Seats
## The match being played, and its world (the same object from round to round).
var game_match: Match
var world: World
## The match's line-up: world slot -> seat (its colour).
var lineup: Array[int] = []
## Matches started on this screen, counting the first.
var matches: int = 0
var road: Road
var cars: Cars
var hud: VersusHud
## The ranking change of each person when the match ended (or was left): slot -> {before, after, delta}.
var ranking_results: Dictionary = {}
var _settled := false


## Builds the screen and starts the first match. The app calls it before adding the screen to the tree, after
## seats.lock().
func setup(p_app: App) -> void:
	app = p_app
	app.tuning.apply(cfg)
	seats = app.seats
	road = $Road
	cars = $Cars
	hud = $Hud
	road.setup(app.atlas, cfg)
	cars.setup(app.atlas)
	hud.setup(app.atlas, cfg)
	new_match()


## A match of the locked line-up, with the next seed.
func new_match() -> void:
	lineup = seats.lineup.duplicate()
	game_match = Match.create(cfg, app.next_seed(), lineup.size(), seats.humans_mask())
	world = game_match.world
	matches += 1
	app.audio.begin_race()
	ranking_results = {}
	_settled = false
	cars.seat_colours = lineup
	app.input.clear_presses()
	app.nav.clear()
	app.clock.reset()
	render()


func frame(steps: int, delta: float) -> void:
	for command: Vector2i in app.nav.take():
		if handle(command.x, command.y):
			return
	for i in steps:
		step_once(seats.step_bytes(lineup.size()))
	render()
	hud.animate(delta)
	app.audio.drive(game_match)
	app.audio.advance(delta)


## One step of the match with one byte per seat.
func step_once(bytes: PackedByteArray) -> void:
	game_match.step(bytes)
	app.audio.race_step(game_match)
	if game_match.phase == Match.MATCH_OVER:
		settle_ranking()


## One menu command from a device. Returns true when it ended this frame: another screen, or a new match.
func handle(device: int, command: int) -> bool:
	var keyboard := device == Nav.KEYBOARD
	if not keyboard and seats.seat_of(device) < 0:
		if command == Nav.ACCEPT:
			seats.claim(device)
		return false
	var plays_keyboard := seats.seat_of(seats.KEYBOARD_DEVICE) >= 0
	if game_match.phase == Match.MATCH_OVER:
		if game_match.phase_ticks < Config.MATCH_CONFIRM_TICKS:
			return false
		if (not keyboard or plays_keyboard) and (command == Nav.ACCEPT or command == Nav.START):
			new_match()
			return true
		if command == Nav.BACK or (not keyboard and command == Nav.SELECT):
			leave_to(app.show_join)
			return true
		return false
	if game_match.phase == Match.ROUND_OVER:
		if keyboard and command == Nav.BACK:
			leave_to(app.show_title)
			return true
		return false
	if world.phase == World.PAUSED:
		if (keyboard and not plays_keyboard and command == Nav.BACK) or (command == Nav.SELECT):
			leave_to(app.show_title)
			return true
		return false
	if keyboard and command == Nav.BACK and _racing() and seats.pad_count() == 0:
		seats.press(PlayerInput.PAUSE)
	return false


func on_focus_lost() -> void:
	if game_match != null and _racing():
		seats.press(PlayerInput.PAUSE)


## True while a round runs (not paused, not between rounds).
func _racing() -> bool:
	return game_match.phase == Match.PLAYING and world.phase == World.RUNNING


## Per slot: true unless it is a person's seat whose pad has gone.
func pads_here() -> Array[bool]:
	var out: Array[bool] = []
	for seat: int in lineup:
		out.append(not seats.is_orphan(seat))
	return out


func render() -> void:
	road.set_scroll(Cars.camera_px(world))
	cars.show_world(world)
	hud.show_match(game_match, lineup, pads_here(), seats.seat_of(seats.KEYBOARD_DEVICE) >= 0, ranking_results, slot_names())


## Goes to another screen. A race match that is not over is left: every person in it counts as having left, last in
## the ranking.
func leave_to(screen: Callable) -> void:
	if game_match.world.is_race() and game_match.phase != Match.MATCH_OVER:
		for p: Car in world.players:
			game_match.abandon(p.slot)
		settle_ranking()
	screen.call()


## Applies the match's result to the ranking (docs/SPEC_RANKING.md §6), once: each person gains or loses points by their
## place among all the cars; bots have no ranking.
func settle_ranking() -> void:
	if _settled or not world.is_race():
		return
	_settled = true
	var order := game_match.ranking_order()
	for place in order.size():
		var slot := order[place]
		if world.players[slot].human == 0:
			continue
		var seat := lineup[slot]
		var player_name := app.names.name_of(seat)
		var result := app.ranking.apply("seat:%d" % seat, player_name, Ranking.delta(order.size(), place))
		result["name"] = player_name
		ranking_results[slot] = result
	app.audio.match_result(game_match, ranking_results)


## What the race tower calls each slot: a person's name from the join screen, BOT for a bot.
func slot_names() -> Array[String]:
	var out: Array[String] = []
	for p: Car in world.players:
		out.append(app.names.name_of(lineup[p.slot]) if p.human != 0 else "BOT")
	return out


func _exit_tree() -> void:
	if app != null and is_instance_valid(app.audio):
		app.audio.stop_loops()
