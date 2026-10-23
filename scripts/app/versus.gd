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
##
## Online (docs/SPEC_ONLINE.md §16, M2): when the app holds an online session (App.start_online_race()), the same screen shows
## the session's match instead of stepping a local one: each frame gives the session the time and the player's controls, and the
## screen draws session.view_match() (the prediction, never ahead of the confirmed phase). There is no pause and no rematch:
## Esc (or a pad's Back) leaves the match (the server counts it as leaving), and once the server ends the match any of Accept, Start
## or Back returns to the online screen. Sounds come from the session's predicted ticks, once each; the match's jingle from the
## confirmed end. Private rooms give no ranking points. The local race above is untouched.
const App := preload("res://scripts/app/app.gd")
const Config := preload("res://scripts/sim/config.gd")
const World := preload("res://scripts/sim/world.gd")
const Car := preload("res://scripts/sim/car.gd")
const Match := preload("res://scripts/sim/match.gd")
const OnlineSession := preload("res://scripts/net/online_session.gd")
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
## The online session this race shows, or null for a local race.
var session: OnlineSession = null
var _settled := false


## Builds the screen and starts the first match. The app calls it before adding the screen to the tree, after
## seats.lock().
func setup(p_app: App) -> void:
	app = p_app
	session = app.online_session
	if session != null:
		cfg = session.cfg
	else:
		app.tuning.apply(cfg)
	seats = app.seats
	road = $Road
	cars = $Cars
	hud = $Hud
	road.setup(app.atlas, cfg)
	cars.setup(app.atlas)
	hud.setup(app.atlas, cfg)
	if session != null:
		start_online()
	else:
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
	if session != null:
		_frame_online(delta)
		return
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
	if session != null:
		return
	if game_match != null and _racing():
		seats.press(PlayerInput.PAUSE)


## True while a round runs (not paused, not between rounds).
func _racing() -> bool:
	return game_match.phase == Match.PLAYING and world.phase == World.RUNNING


## Per slot: true unless it is a person's seat whose pad has gone.
func pads_here() -> Array[bool]:
	if session != null:
		var all: Array[bool] = []
		all.resize(lineup.size())
		all.fill(true)
		return all
	var out: Array[bool] = []
	for seat: int in lineup:
		out.append(not seats.is_orphan(seat))
	return out


func render() -> void:
	var shown := world if session == null else _eased(world)
	road.set_scroll(Cars.camera_px(shown))
	cars.show_world(shown)
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
	if session != null:
		return _online_names()
	var out: Array[String] = []
	for p: Car in world.players:
		out.append(app.names.name_of(lineup[p.slot]) if p.human != 0 else "BOT")
	return out


func _exit_tree() -> void:
	if session != null:
		session.on_predicted_tick = Callable()
	if app != null and is_instance_valid(app.audio):
		app.audio.stop_loops()


# --- Online ----------------------------------------------------------------------------------------------------------------


## Shows the session's match: the line-up is the server's seats, in order.
func start_online() -> void:
	lineup = []
	for seat in session.seats:
		lineup.append(seat)
	game_match = session.view_match()
	world = game_match.world
	matches = 1
	app.audio.begin_race()
	ranking_results = {}
	_settled = false
	cars.seat_colours = lineup
	session.on_predicted_tick = func(m: Match) -> void: app.audio.race_step(m)
	app.input.clear_presses()
	app.nav.clear()
	app.clock.reset()
	render()


func _frame_online(delta: float) -> void:
	for command: Vector2i in app.nav.take():
		if handle_online(command.x, command.y):
			return
	session.update(app.online_now(), app.input.step_byte())
	if session.state == OnlineSession.State.FAILED or session.state == OnlineSession.State.REJECTED:
		app.show_online("CONNECTION LOST")
		return
	game_match = session.view_match()
	world = game_match.world
	if session.state == OnlineSession.State.ENDED and not _settled:
		_settled = true
		app.audio.match_result(session.confirmed_match(), {})
	render()
	hud.animate(delta)
	app.audio.drive(game_match)
	app.audio.advance(delta)


## One menu command of an online race: leaving, or going on once the match is over. Returns true when the screen changed.
func handle_online(device: int, command: int) -> bool:
	var over := game_match.phase == Match.MATCH_OVER and game_match.phase_ticks >= Config.MATCH_CONFIRM_TICKS
	var leave := command == Nav.BACK or (device != Nav.KEYBOARD and command == Nav.SELECT)
	if over and (leave or command == Nav.ACCEPT or command == Nav.START):
		app.show_online()
		return true
	if not over and game_match.phase != Match.MATCH_OVER and leave:
		app.show_online()
		return true
	return false


func _online_names() -> Array[String]:
	var names: PackedStringArray = session.lobby.get("names", PackedStringArray())
	var out: Array[String] = []
	for p: Car in world.players:
		if p.human == 0:
			out.append("BOT")
		elif p.slot < names.size() and not names[p.slot].is_empty():
			out.append(names[p.slot])
		else:
			out.append("P%d" % (p.slot + 1))
	return out


## What the cars and the camera are drawn from: the world, or, while a rollback's jump is still fading (session.view_offset()), a
## copy of it with the cars and the camera set back where they were drawn before the jump. The simulation never sees the copy.
func _eased(w: World) -> World:
	var moved := false
	for p: Car in w.players:
		moved = moved or session.view_offset(p.slot) != Vector2.ZERO
	if not moved:
		return w
	var copy := w.clone()
	var lead_y := -INF
	var lead_shift := 0.0
	for p: Car in copy.players:
		var off := session.view_offset(p.slot)
		p.x += off.x
		p.y_world += off.y
		if p.alive != 0 and p.y_world > lead_y:
			lead_y = p.y_world
			lead_shift = off.y
	copy.camera_y += lead_shift
	return copy
