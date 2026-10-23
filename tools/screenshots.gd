extends "res://tools/tool_base.gd"
## Screenshots of the game for docs/screenshots/ (docs/GODOT_PLAN.md §6). Needs a display and a renderer.
## tools/run_tool.sh screenshots [--out=DIR --seed=N] imports the project and runs this command, then fails on any
## ERROR line of the output, as tools/test.sh does:
##
##   xvfb-run -a -s "-screen 0 1920x1080x24" godot --rendering-driver opengl3 --fixed-fps 60 --path . \
##       -s res://tools/screenshots.gd [-- --out=DIR --seed=N]
##
## It plays the real game with key events (Enter, X held, Esc; the tool_base.gd autopilot steers with the arrow
## keys) and saves:
##   01-title.png        the title screen;
##   02-game.png         a game in high gear, once several cars are on screen;
##   03-pause.png        the pause panel, one tick after 02 (the Esc sent after 02 reaches the game a frame later);
##   04-game-over.png    the game-over panel (the tank set to 0.1, so it runs dry within 6 ticks);
##   05-stage-clear.png  the stage-clear panel (the car set just short of the goal);
##   06-skid-low-fuel.png  staged: a skid (the 45-degree frame) with its message, the low-fuel warning, a rainbow fuel
##                       car, a truck and an oil patch, all at once.
## Then the versus mode (B2), played with synthetic pads (VERSUS_PADS) as players would: the tank runs dry, Esc goes to
## the title, Down and Enter open the join screen, three pads press A and one presses Right twice (two bots), a fourth
## pad joins and Start begins a match of six cars; each pad drives its car (tool_base.gd pad_autopilot(): B, then A
## from its own shift speed, and the D-pad towards the clearest lane); each round ends when the tool empties P1's tank,
## and P2's A starts the next one.
##   07-versus-join.png  the join screen: P1 to P3 ready, two bots, the sixth seat free (PRESS A lit);
##   08-versus-race.png  staged in round 2: the six cars in six colours, one per lane, all on screen (the leader on the
##                       camera line, the last on the bottom edge: EDGE), with traffic ahead; the six seat panels with a
##                       pip for round 1's winner, P4's tank low (LOW FUEL lit) and P3's pad gone (NO PAD);
##   09-versus-pause.png the pause panel, Start on P2's pad;
##   10-round-over.png   round 1's panel once A counts (PRESS A), P1 out;
##   11-match-over.png   the match's panel once its keys count.
## The race picture is checked by sampling its pixels, twice, and the run fails unless both pass: as drawn, against the
## world it shows (check_race_colours(): each seat's car shows its colours where the view drew it, and no colour on a
## traffic sprite there, the fuel car excepted, is a player colour); and as saved, by its pixels alone
## (tests/race_picture.gd, which tests/test_versus_look.gd also runs on the committed picture: six cars in six
## colours, the traffic's colours sampled on the same picture, none of them a player colour or near one).
## Each PNG is the 640x360 viewport scaled 2x with Nearest, so its pixels are the game's pixels (tools/scalecheck.gd
## checks that the window shows exactly the viewport). Exit code 0 when every shot was saved and no error was logged
## until the game's nodes were freed (tools/tool_base.gd).

const Hud := preload("res://scripts/view/hud.gd")
const ViewConfig := preload("res://scripts/view/view_config.gd")
const Atlas := preload("res://scripts/view/atlas.gd")
const Cars := preload("res://scripts/view/cars.gd")
const Draw := preload("res://scripts/view/draw.gd")
const PlayerColours := preload("res://scripts/view/player_colours.gd")
const JoinView := preload("res://scripts/view/join_view.gd")
const Match := preload("res://scripts/sim/match.gd")
const RacePicture := preload("res://tests/race_picture.gd")

const OUT_DEFAULT := "res://docs/screenshots"
const SEED_DEFAULT := 20261015
## Give up waiting for traffic after this many frames of driving and take the shot anyway.
const TRAFFIC_WAIT := 3600
const SCALE := 2
const SHOTS := 11
## Versus: the pads (synthetic devices), in the order they join (P1 to P4).
const VERSUS_PADS: Array[int] = [10, 11, 12, 13]
## Each pad's car shifts to high gear at this speed (km/h), so the four drive a little differently.
const SHIFT_KMH: Array[float] = [160.0, 170.0, 180.0, 190.0]
## Steps of a round after which the tool empties P1's tank, so the round ends.
const ROUND_STEPS := 600
## Steps of round 2 after which the race picture is staged.
const STAGE_RACE_AFTER := 600
## The staged race: per world slot, [lane, screen y of the car's front edge]. Slot 0 leads, on the camera line; the
## last car is on the bottom edge (its rear at Config.edge_bottom).
const FORMATION := [[2, 192], [4, 216], [0, 240], [5, 266], [1, 294], [3, 328]]
## Traffic placed ahead of the staged cars: [kind, lane, screen y of its top].
const RACE_TRAFFIC := [
	[Config.KIND_YELLOW, 1, 70], [Config.KIND_RED, 3, 40], [Config.KIND_BLUE, 0, 120], [Config.KIND_TRUCK, 5, 24],
	[Config.KIND_YELLOW, 4, 140],
]

var out_dir: String
## The step of the script below, and the frame it started.
var _stage: int = 0
var _since: int = 0
var _saved: Array[String] = []
## Versus: the round in which the tool last emptied P1's tank.
var _emptied_round: int = 0


func _initialize() -> void:
	if not begin():
		finish(1)
		return
	if DisplayServer.get_name() == "headless":
		printerr("screenshots: needs a display and a renderer (xvfb-run, --rendering-driver opengl3), not --headless")
		finish(1)
		return
	out_dir = ProjectSettings.globalize_path(user_arg("out", OUT_DEFAULT))
	DirAccess.make_dir_recursive_absolute(out_dir)
	start_app(user_arg("seed", str(SEED_DEFAULT)).to_int())


func _process(_delta: float) -> bool:
	frame += 1
	var waited := frame - _since
	var w := world()
	match _stage:
		0:  # The title, with the prompt at full brightness (it dims after half a second).
			if waited == 20:
				_shot("01-title")
				# The single-player game is no longer on the title (LOCAL opens the join screen): start it as the app would.
				app.start_game()
				_next()
		1:  # Driving: hold X (high gear), keep clear of trouble, and wait for a busy road.
			if w != null and waited == 2:
				key(KEY_X, true)
			autopilot()
			if w != null and w.phase == World.GAME_OVER:
				tap(KEY_ENTER)
			elif waited > 300 and (_busy_road() or waited > TRAFFIC_WAIT):
				hold_steer(KEY_NONE)
				_shot("02-game")
				tap(KEY_ESCAPE)
				_next()
		2:  # Paused.
			if waited == 4 and _expect(w != null and w.phase == World.PAUSED, "the game did not pause"):
				_shot("03-pause")
				tap(KEY_ESCAPE)
				_next()
		3:  # Run the tank dry.
			if waited == 4 and _expect(w != null and w.phase == World.RUNNING, "the game did not resume"):
				w.player().fuel = 0.1
			if w != null and w.phase == World.GAME_OVER and waited > 30:
				_shot("04-game-over")
				tap(KEY_ENTER)
				_next()
		4:  # A new game, put just short of the goal.
			if waited == 120 and _expect(w != null and w.phase == World.RUNNING, "no new game after Enter"):
				w.player().y_world = w.goal - 2.0
			if w != null and w.phase == World.STAGE_CLEAR and waited > 150:
				_shot("05-stage-clear")
				tap(KEY_ENTER)
				_next()
		5:  # Stage 2: stage a skid, low fuel and every kind of traffic, timed so that at the shot the low-fuel warning
			# is lit and the fuel car's rainbow is at magenta, a colour no other car has.
			if w != null and waited > 240 and w.phase == World.RUNNING and _good_moment(w.stage_ticks + 2):
				_stage_details(w)
				_next()
		6:
			if waited == 2:
				_shot("06-skid-low-fuel")
				_next()
		7:  # Versus: run the tank dry, then Esc at the game over goes to the title.
			if waited == 2:
				key(KEY_X, false)
				if w != null:
					w.player().fuel = 0.1
			if w != null and w.phase == World.GAME_OVER and waited > 30:
				tap(KEY_ESCAPE)
				_next()
		8:  # The title: LOCAL is shown, Enter opens the join screen.
			if waited == 20:
				_expect(on_title(), "Esc at the game over did not go to the title")
			if waited == 24:
				tap(KEY_ENTER)
			if waited > 24 and join_screen() != null:
				_next()
		9:  # Three pads join; the bots fill the three empty seats by themselves.
			var at: Array[int] = [6, 10, 14]
			for i in at.size():
				if waited == at[i]:
					pad_tap(VERSUS_PADS[i], JOY_BUTTON_A)
			if waited > 40 and _blink_lit(join_screen()):
				if _expect(app.seats.people() == 3 and app.seats.bots == 3, "the join screen does not have 3 pads and 3 bots"):
					_shot("07-versus-join")
					pad_tap(VERSUS_PADS[3], JOY_BUTTON_A)
					_next()
		10:  # The fourth pad has joined: six cars. Start.
			if waited == 4:
				pad_tap(VERSUS_PADS[0], JOY_BUTTON_START)
			if waited > 4 and versus() != null:
				_expect(app.seats.lineup.size() == 6, "the race does not have six cars")
				_next()
		11:  # Round 1: the pads drive; P1's tank runs dry; the round's panel once A counts.
			_drive_pads()
			var m := _match()
			if m.phase == Match.PLAYING:
				_end_round_after(ROUND_STEPS)
			elif m.phase == Match.ROUND_OVER and m.phase_ticks == Config.MATCH_CONFIRM_TICKS + 4:
				_shot("10-round-over")
				pad_press_a(VERSUS_PADS[1])
				_next()
		12:  # Round 2 (or a later one, if a round ends early): stage the race picture.
			_drive_pads()
			var m := _match()
			var vw: World = versus().world
			if m.phase == Match.ROUND_OVER and m.phase_ticks == Config.MATCH_CONFIRM_TICKS + 4:
				pad_press_a(VERSUS_PADS[1])
			elif m.phase == Match.PLAYING and m.round_number >= 2 and vw.phase == World.RUNNING:
				if vw.stage_ticks >= STAGE_RACE_AFTER and _warning_lit(vw.stage_ticks + 2):
					_stage_race(versus())
					_next()
			_expect(m.phase != Match.MATCH_OVER, "the match ended before the race picture")
		13:  # The race picture, checked by its pixels twice: as drawn, against the world it shows
			# (check_race_colours()), and as saved, alone (tests/race_picture.gd).
			_drive_pads()
			if waited == 2:
				var check := check_race_colours(viewport_image(), versus())
				var problems: PackedStringArray = check["problems"]
				_shot("08-versus-race")
				var saved := RacePicture.check(RacePicture.load_png(out_dir.path_join("08-versus-race.png")), app.atlas)
				for problem: String in saved["problems"]:
					problems.append("the saved file: " + problem)
				for problem: String in problems:
					printerr("screenshots: 08-versus-race: ", problem)
				if problems.is_empty():
					print("screenshots: 08-versus-race colour check: %d cars in their seats' colours, %d traffic sprites without a player colour" % [
						check["cars"], check["traffic"]
					])
					var sprites: int = (saved["traffic"] as Dictionary).values().reduce(func(sum: int, n: int) -> int: return sum + n, 0)
					print("screenshots: 08-versus-race.png by its pixels: %d cars in %d colours, %d traffic cars; the nearest traffic colour %.1f away (bodies %.1f, CIEDE2000)" % [
						saved["cars"], (saved["colours"] as Array).size(), sprites, saved["nearest_shade"], saved["nearest_body"]
					])
				if _expect(problems.is_empty(), "the race picture failed its colour check"):
					pad_tap(VERSUS_PADS[1], JOY_BUTTON_START)
					_next()
		14:  # Paused by P2's Start.
			if waited == 4 and _expect(versus().world.phase == World.PAUSED, "Start did not pause the round"):
				_shot("09-versus-pause")
				pad_tap(VERSUS_PADS[1], JOY_BUTTON_START)
				_next()
		15:  # Resumed; P3's pad comes back and takes its seat with A. Rounds go on until the match is over.
			_drive_pads()
			var m := _match()
			if waited == 2:
				_expect(versus().world.phase == World.RUNNING, "Start did not resume the round")
				Input.joy_connection_changed.emit(VERSUS_PADS[2], true)
				pad_press_a(VERSUS_PADS[2])
			if waited == 4:
				_expect(app.seats.seat_of(VERSUS_PADS[2]) == 2, "P3's pad did not take its seat back")
			if m.phase == Match.PLAYING and waited > 4:
				_end_round_after(ROUND_STEPS)
			elif m.phase == Match.ROUND_OVER and m.phase_ticks == Config.MATCH_CONFIRM_TICKS + 4:
				pad_press_a(VERSUS_PADS[1])
			elif m.phase == Match.MATCH_OVER and m.phase_ticks == Config.MATCH_CONFIRM_TICKS + 4:
				_shot("11-match-over")
				_next()
		16:
			for device: int in VERSUS_PADS:
				pad_let_go(device)
			var saved_line := "screenshots: saved %s in %s" % [", ".join(_saved), out_dir]
			if _saved.size() == SHOTS:
				finish(0, saved_line)
			else:
				print(saved_line)
				finish(1)
	if frame > 30000:
		printerr("screenshots: stuck at step %d" % _stage)
		finish(1)
	return false


# --- Versus ----------------------------------------------------------------------------------------------------------


## Every pad drives its car (tool_base.gd pad_autopilot()), each shifting at its own speed (SHIFT_KMH).
func _drive_pads() -> void:
	if versus() == null:
		return
	for i in VERSUS_PADS.size():
		pad_autopilot(VERSUS_PADS[i], SHIFT_KMH[i])


func _match() -> Match:
	var screen := versus()
	return screen.game_match if screen != null else null


## Once a round has run `steps` steps, empties P1's tank (slot 0) to less than one step's drain, once, so it goes out
## on the next step and the round ends.
func _end_round_after(steps: int) -> void:
	var m := _match()
	var vw: World = m.world
	if vw.phase == World.RUNNING and vw.stage_ticks >= steps and vw.players[0].alive != 0 and _emptied_round != m.round_number:
		vw.players[0].fuel = 0.01
		_emptied_round = m.round_number


## True while the free cards' PRESS A is lit, in the middle of its half second (so the last drawn frame shows it).
static func _blink_lit(screen: Node) -> bool:
	if screen == null:
		return false
	var phase := fmod(float(screen.time), JoinView.BLINK_SECONDS * 2.0)
	return phase > 0.1 and phase < JoinView.BLINK_SECONDS - 0.1


## True at a stage tick when the blinking marks (LOW FUEL) are lit.
static func _warning_lit(stage_tick: int) -> bool:
	return floori(stage_tick / float(Hud.WARN_BLINK_TICKS)) % 2 == 0


## Stages the race picture: the six cars one per lane (FORMATION), none skidding or blinking; the traffic cleared from
## the cars' half of the screen and RACE_TRAFFIC placed ahead; P4's tank at 14 (LOW FUEL); P3's pad gone (NO PAD).
func _stage_race(screen: Node) -> void:
	var vw: World = screen.world
	var kept: Array[Traffic] = []
	for c: Traffic in vw.traffic:
		if c.kind != Config.KIND_FUEL_CAR and vw.screen_y(c.y_world) + c.h < 0.0:
			kept.append(c)
	vw.traffic = kept
	for entry: Array in RACE_TRAFFIC:
		var kmh := Config.TRUCK_SPEED if entry[0] == Config.KIND_TRUCK else 100.0
		_place(vw, entry[0], entry[1], entry[2], kmh)
	for slot in vw.players.size():
		var p: Car = vw.players[slot]
		var spot: Array = FORMATION[slot]
		p.x = Traffic.lane_x(vw.cfg, spot[0], p.w)
		p.y_world = vw.camera_y + vw.anchor - float(spot[1])
		p.slide_vx = 0.0
		p.invulnerable = 0
		p.fuel = maxf(p.fuel, 40.0)
	vw.players[3].fuel = 14.0
	Input.joy_connection_changed.emit(VERSUS_PADS[2], false)


## Checks the race picture by its pixels (the viewport image, 640x360). Each seat's car, where the view drew it, shows
## its body colour on at least half the body pixels of its frame, and its dark and light shades; none of the 18 player
## colours is on any traffic sprite on screen (the fuel car, the declared exception, aside), nor is any colour of the
## traffic frames in the atlas a player colour. Returns {problems (empty when all is well), cars (checked), traffic
## (sprites compared)}.
static func check_race_colours(image: Image, screen: Node) -> Dictionary:
	var problems := PackedStringArray()
	var cars := 0
	var vw: World = screen.world
	var lineup: Array[int] = screen.lineup
	var atlas: Atlas = screen.app.atlas
	var player_colours := {}
	for seat in PlayerColours.COUNT:
		for rank in PlayerColours.SOURCE.size():
			player_colours[PlayerColours.shade(seat, rank).to_html(false)] = seat
	for slot in vw.players.size():
		var p: Car = vw.players[slot]
		var seat := lineup[slot]
		var spec := Cars.seat_car_sprite(p, lineup)
		var rect := _sprite_rect(atlas, spec, Cars.hitbox_pos(vw, p.x, p.y_world), Vector2i(roundi(p.w), roundi(p.h)))
		var counts := _colour_counts(image, rect)
		var body_pixels := _body_pixels(atlas, spec["frame"], seat)
		var body := PlayerColours.colour(seat).to_html(false)
		if p.alive == 0 or not Cars.player_visible(p, vw.stage_ticks):
			problems.append("slot %d (seat %d) is not on screen to check" % [slot, seat])
			continue
		var before := problems.size()
		if int(counts.get(body, 0)) * 2 < body_pixels:
			problems.append("seat %d's body colour %s covers %d px of its car, under half of %d" % [seat, body, counts.get(body, 0), body_pixels])
		for rank: int in [PlayerColours.DARK, PlayerColours.LIGHT]:
			var html := PlayerColours.shade(seat, rank).to_html(false)
			if int(counts.get(html, 0)) == 0:
				problems.append("seat %d's shade %s is not on its car" % [seat, html])
		if problems.size() == before:
			cars += 1
	var seen := 0
	for c: Traffic in vw.traffic:
		if c.kind == Config.KIND_FUEL_CAR:
			continue
		var rect := _sprite_rect(atlas, ViewConfig.TRAFFIC[c.kind], Cars.hitbox_pos(vw, c.x, c.y_world), Vector2i(roundi(c.w), roundi(c.h)))
		rect = rect.intersection(Rect2i(0, 0, ViewConfig.VIEW_W, ViewConfig.VIEW_H))
		if rect.has_area():
			seen += 1
		for html: String in _colour_counts(image, rect):
			if player_colours.has(html):
				problems.append("a %s on screen shows %s, seat %d's colour" % [Config.KIND_NAMES[c.kind], html, player_colours[html]])
	if seen < 3:
		problems.append("only %d traffic sprites on screen to compare" % seen)
	for colour: Color in PlayerColours.traffic_colours(atlas):
		if player_colours.has(colour.to_html(false)):
			problems.append("the traffic frames have %s, a player colour" % colour.to_html(false))
	if cars != PlayerColours.COUNT:
		problems.append("%d cars of %d showed their seats' colours" % [cars, PlayerColours.COUNT])
	return {"problems": problems, "cars": cars, "traffic": seen}


## Where a sprite is drawn on its hitbox: its frame at ViewConfig.SPRITE_SCALE, placed by Draw.place_on_hitbox().
static func _sprite_rect(atlas: Atlas, spec: Dictionary, box: Vector2i, box_size: Vector2i) -> Rect2i:
	var size := atlas.frame_size(spec["frame"])
	var at := Draw.place_on_hitbox(size, int(spec["shadow"]), ViewConfig.SPRITE_SCALE, box, box_size)
	return Rect2i(at, size * ViewConfig.SPRITE_SCALE)


## html -> pixel count of an image's pixels in a rect.
static func _colour_counts(image: Image, rect: Rect2i) -> Dictionary:
	var counts := {}
	var r := rect.intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var html := image.get_pixel(x, y).to_html(false)
			counts[html] = int(counts.get(html, 0)) + 1
	return counts


## How many pixels of a seat's frame are its body colour, at ViewConfig.SPRITE_SCALE.
static func _body_pixels(atlas: Atlas, frame: String, seat: int) -> int:
	var image := PlayerColours.image_of(atlas.frame(frame))
	var count := 0
	if image == null:
		return 0
	var body := PlayerColours.colour(seat)
	for y in image.get_height():
		for x in image.get_width():
			var pixel := image.get_pixel(x, y)
			if pixel.a8 > 0 and pixel.r8 == body.r8 and pixel.g8 == body.g8 and pixel.b8 == body.b8:
				count += 1
	return count * ViewConfig.SPRITE_SCALE * ViewConfig.SPRITE_SCALE


## Fails the run with a message unless ok.
func _expect(ok: bool, what: String) -> bool:
	if not ok:
		printerr("screenshots: ", what)
		finish(1)
	return ok


func _next() -> void:
	_stage += 1
	_since = frame


## Three or more cars on screen ahead of the player, the player in plain view (not blinking or skidding) and some
## points already scored.
func _busy_road() -> bool:
	var w := world()
	if w == null or w.phase != World.RUNNING:
		return false
	var p := w.player()
	if p.invulnerable > 0 or p.is_skidding() or p.score == 0:
		return false
	var cars := 0
	for c: Traffic in w.traffic:
		var top := w.screen_y(c.y_world)
		if c.is_car() and top > 24.0 and top < 260.0:
			cars += 1
	return cars >= 3


## True at a stage tick when the low-fuel warning (it blinks every WARN_BLINK_TICKS) is lit and the rainbow's hue is
## between 280 and 320 degrees.
static func _good_moment(stage_tick: int) -> bool:
	var lit := floori(stage_tick / float(Hud.WARN_BLINK_TICKS)) % 2 == 0
	var hue := posmod(stage_tick * ViewConfig.RAINBOW_DEGREES_PER_TICK, 360)
	return lit and hue >= 280 and hue <= 320


## Puts a fuel car, a truck, a yellow car and an oil patch around the player, sends it into a skid with its message,
## and leaves 15 units in the tank.
func _stage_details(w: World) -> void:
	var p := w.player()
	var lane := Traffic.lane_of(w.cfg, p.x, p.w)
	var side := 1 if lane < w.cfg.lane_count - 2 else -1
	_place(w, Config.KIND_FUEL_CAR, lane + side, 228.0, Config.FUEL_CAR_SPEED)
	_place(w, Config.KIND_TRUCK, lane + 2 * side, 48.0, Config.TRUCK_SPEED)
	_place(w, Config.KIND_YELLOW, lane - side, 200.0, 100.0)
	_place(w, Config.KIND_OIL, lane, w.anchor + p.h + 4.0, 0.0)
	p.fuel = 15.0
	Car.start_skid(w.cfg, p, side)
	var screen := game()
	screen.message = "OIL! STEER INTO THE SLIDE"
	screen.message_time = 1.0
	hold_steer(KEY_NONE)


## A traffic object of a kind in a lane (clamped to the road), with its top at a screen y.
static func _place(w: World, kind: int, lane: int, screen_top: float, kmh: float) -> void:
	var c := Traffic.new()
	c.id = 900 + w.traffic.size()
	c.kind = kind
	c.w = w.cfg.kind_w[kind]
	c.h = w.cfg.kind_h[kind]
	c.x = Traffic.lane_x(w.cfg, clampi(lane, 0, w.cfg.lane_count - 1), c.w)
	c.y_world = w.camera_y + w.anchor - screen_top
	c.kmh = kmh
	c.lane_timer = 1000000
	w.traffic.append(c)


func _shot(name: String) -> void:
	var image := viewport_image()
	image.resize(image.get_width() * SCALE, image.get_height() * SCALE, Image.INTERPOLATE_NEAREST)
	var path := out_dir.path_join(name + ".png")
	if image.save_png(path) == OK:
		_saved.append(name + ".png")
	else:
		printerr("screenshots: could not save ", path)
