extends RefCounted
## The whole simulation: seats (player cars), traffic, spawner, RNG, camera and phase, and step(), which advances
## it by one tick of 1/60 s (docs/GODOT_PLAN.md §3; src/game/state.ts in the Phaser version, commit 0a0841f).
##
## Pure and deterministic: no nodes, autoloads, engine singletons, clock or global RNG. The same seed and the same
## input bytes give the same world, bit for bit (checksum()).
##
## Coordinates: x is screen px (left edge of the hitbox). y_world grows forward, in world px; a car's front edge is
## at y_world. On screen, top = anchor + (camera_y - y_world): screen_y(). The camera is monotonic and follows the
## leading live car, which sits on the anchor line. Per-seat traffic flags are bit masks.
##
## Two modes:
## - MODE_STAGES, World.new(cfg, seed): single player, the Phaser rules converted by K (config.gd), anchor 292.
## - MODE_VERSUS, World.versus(cfg, seed, seats, humans): 2 to 6 seats, humans and bots, one round of endless
##   survival (docs/GODOT_PLAN.md §7). Anchor 192. The bottom edge pushes the stragglers and drains their fuel; cars
##   pass through each other; points for passes, fuel cars and distance; denser traffic every 20 s; an empty tank or
##   a truck puts a seat out. A human out (or, against a single human, the last bot out) ends the round at the end
##   of the step: phase ROUND_OVER, with `winner` set. Each seat draws its own random events from its own stream
##   (Car.rng), so the number of seats never changes the traffic's draws. A seat whose byte is 0xFF is driven by its
##   bot (bot.gd, `bots`), which has a stream of its own too. match.gd plays rounds of one world into a match.

const Self := preload("res://scripts/sim/world.gd")
const Config := preload("res://scripts/sim/config.gd")
const Rng := preload("res://scripts/sim/rng.gd")
const Car := preload("res://scripts/sim/car.gd")
const Traffic := preload("res://scripts/sim/traffic.gd")
const Fuel := preload("res://scripts/sim/fuel.gd")
const Collision := preload("res://scripts/sim/collision.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")
const Bot := preload("res://scripts/sim/bot.gd")

## Layout version of to_array(). 2: the versus fields (World.winner, and Car.human to Car.rng). 3: the bots.
const FORMAT := 3

## Single-player stages: the Phaser game.
const MODE_STAGES := 0
## Versus rounds for 2 to 6 seats (docs/GODOT_PLAN.md §7). World.versus() makes one.
const MODE_VERSUS := 1

## Phases. PHASE_NAMES are the single-player phases, whose codes tests/golden/phaser_golden.json uses; ROUND_OVER is
## the versus mode's end of a round. ALL_PHASE_NAMES names every code.
const RUNNING := 0
const PAUSED := 1
const STAGE_CLEAR := 2
const GAME_OVER := 3
const ROUND_OVER := 4
const PHASE_NAMES := ["running", "paused", "stage_clear", "game_over"]
const ALL_PHASE_NAMES := PHASE_NAMES + ["round_over"]

## Events of the last step, as bits. Car.events holds a seat's own; World.events holds all of them plus the
## world-wide ones (stage clear, game over, pause, resume, round over). EVENT_NAMES are Phaser's, whose bits the
## golden file uses; ALL_EVENT_NAMES adds the versus mode's.
const EV_SKID := 1
const EV_BUMP := 2
const EV_CRASH := 4
const EV_SPIN := 8
const EV_PICKUP := 16
const EV_PASS := 32
const EV_STAGE_CLEAR := 64
const EV_GAME_OVER := 128
const EV_PAUSE := 256
const EV_RESUME := 512
## Versus: the seat went out of the round this step (an empty tank, or a truck).
const EV_OUT := 1024
## Versus: the round ended this step; World.winner says who won it.
const EV_ROUND_OVER := 2048
const EVENT_NAMES := ["skid", "bump", "crash", "spin", "pickup", "pass", "stage_clear", "game_over", "pause", "resume"]
const ALL_EVENT_NAMES := EVENT_NAMES + ["out", "round_over"]

## World.winner while there is none: the round is not over, or it ended without a winner.
const NO_WINNER := -1

## The scalar fields, in to_array() order. tests/test_world_state.gd checks that to_array() covers every field.
const SCALARS := [
	"game_seed", "mode", "tick", "phase", "stage", "goal", "gap_scale", "stage_ticks", "camera_y", "anchor",
	"high_score", "events", "winner"
]

var cfg: Config
var rng: Rng
## The seed this world started from. The RNG state moves on; this does not. Each seat's own stream is seeded from
## it (seat_seed()), and a new game after a game over can use game_seed + 1.
var game_seed: int = 0
var mode: int = MODE_STAGES
## Steps taken, in any phase.
var tick: int = 0
var phase: int = RUNNING
## Single player: the stage. Versus: always 1.
var stage: int = 1
## Distance to cover this stage, in world px. Versus: 0, there is no goal.
var goal: float = 0.0
## Single player: product of SPAWN_GAP_SCALE, once per stage after the first. Versus: product of VERSUS_GAP_SHRINK,
## once every VERSUS_SHRINK_TICKS running ticks of the round; it scales the car and oil gaps only.
var gap_scale: float = 1.0
## Running ticks this stage (Phaser's `time`, in ticks). Versus: running ticks this round, the difficulty clock.
var stage_ticks: int = 0
var camera_y: float = 0.0
## Screen y of the front edge of the car the camera follows: 292 single player, 192 versus.
var anchor: float = 0.0
## Best score this session. The caller passes it to the next World. Versus leaves it alone.
var high_score: int = 0
var events: int = 0
## Versus: the seat that won the round, once phase is ROUND_OVER; NO_WINNER until then, or if nobody won. Always a
## human seat.
var winner: int = NO_WINNER
var players: Array[Car] = []
var traffic: Array[Traffic] = []
var spawner: Traffic.Spawner
## Versus: one bot per seat (bot.gd), whichever seat it is, so a human seat whose controller goes away can be driven
## too. Single player has none: a 0xFF seat there gets no input, as in A1.
var bots: Array[Bot] = []


## A new game: stage 1, full tanks, empty road. Every seat starts at the same place, in cfg.start_lane at
## y_world 0 (cars pass through each other). Draws three RNG values (the spawner), as Phaser's createGame().
## p_mode and p_humans make a versus world instead: use World.versus(), which checks them first.
func _init(
	p_cfg: Config, p_seed: int, p_seats: int = 1, p_high_score: int = 0, p_mode: int = MODE_STAGES,
	p_humans: int = 1
) -> void:
	cfg = p_cfg
	rng = Rng.new(p_seed)
	game_seed = p_seed & 0xFFFFFFFF
	high_score = p_high_score
	if p_mode == MODE_VERSUS:
		_init_versus(p_seats, p_humans)
		return
	anchor = cfg.anchor_single
	goal = cfg.stage_goal(stage)
	for slot in p_seats:
		var car := Car.new()
		car.slot = slot
		car.w = cfg.player_w
		car.h = cfg.player_h
		car.x = Traffic.lane_x(cfg, cfg.start_lane, car.w)
		car.rng = Rng.new(seat_seed(game_seed, slot))
		players.append(car)
	spawner = Traffic.create_spawner(cfg, gap_scale, rng)


## A versus round (docs/GODOT_PLAN.md §7) for p_seats seats: seat s is a person's if p_humans has its bit (1 << s),
## a bot's otherwise, for good. Each seat starts in its lane of Config.VERSUS_START_LANES, on the anchor line, and
## the round is RUNNING. null (with an error) when versus_valid() is false.
static func versus(p_cfg: Config, p_seed: int, p_seats: int, p_humans: int) -> Self:
	if not versus_valid(p_cfg, p_seats, p_humans):
		push_error("World.versus: needs the standard profile, %d to %d seats and at least one human seat" % [
			Config.VERSUS_SEATS_MIN, Config.VERSUS_SEATS_MAX
		])
		return null
	return Self.new(p_cfg, p_seed, p_seats, 0, MODE_VERSUS, p_humans)


## True when World.versus() takes these seats: the standard profile, VERSUS_SEATS_MIN to VERSUS_SEATS_MAX seats, and
## a human mask with at least one human and no bit past the last seat. (With one human the join screen must add a
## bot: two cars at least.)
static func versus_valid(p_cfg: Config, p_seats: int, p_humans: int) -> bool:
	if p_cfg.profile != Config.PROFILE_STANDARD:
		return false
	if p_seats < Config.VERSUS_SEATS_MIN or p_seats > Config.VERSUS_SEATS_MAX:
		return false
	return p_humans > 0 and p_humans < (1 << p_seats)


## Seed of a slot's own RNG stream (Car.rng): the world's seed moved (slot + 1) x 2^28 draws along mulberry32's
## cycle (Config.SEAT_SEED_STEP). Slots 0 to 14 give streams that never overlap the world's or each other's within
## 2^28 draws.
static func seat_seed(p_game_seed: int, p_slot: int) -> int:
	return (p_game_seed + (p_slot + 1) * Config.SEAT_SEED_STEP) & 0xFFFFFFFF


## Seed of a seat's bot stream (Bot.rng): seat_seed() of slot + Config.BOT_STREAM_SLOT_OFFSET, so slots 6 to 11,
## apart from the world's stream and the seats' own.
static func bot_seed(p_game_seed: int, p_slot: int) -> int:
	return seat_seed(p_game_seed, p_slot + Config.BOT_STREAM_SLOT_OFFSET)


func _init_versus(p_seats: int, p_humans: int) -> void:
	mode = MODE_VERSUS
	anchor = cfg.anchor_versus
	goal = 0.0
	for slot in p_seats:
		var car := Car.new()
		car.slot = slot
		car.w = cfg.player_w
		car.h = cfg.player_h
		car.human = (p_humans >> slot) & 1
		car.rng = Rng.new(seat_seed(game_seed, slot))
		players.append(car)
		bots.append(Bot.new(bot_seed(game_seed, slot)))
	start_round()


## Versus: starts a round. Every seat is back in its start lane on the anchor line, alive, stopped in low gear, with
## a full tank and no score, distance, skid or invulnerability. The road is empty, the gaps and the difficulty clock
## (gap_scale, stage_ticks) start over with a new spawner (three world-RNG draws), every bot starts afresh
## (Bot.reset()), the phase is RUNNING and nobody has won. Kept: the world RNG, every seat's stream and every bot's
## (they continue, plan §7), the human flags, tick, game_seed. World.versus() calls it, and match.gd for each later
## round.
func start_round() -> void:
	var lanes: Array = Config.VERSUS_START_LANES[players.size()]
	for p: Car in players:
		p.x = Traffic.lane_x(cfg, lanes[p.slot], p.w)
		p.y_world = 0.0
		p.speed = 0.0
		p.gear = Car.GEAR_LOW
		p.slide_vx = 0.0
		p.invulnerable = 0
		p.fuel = Config.FUEL_MAX
		p.score = 0
		p.alive = 1
		p.events = 0
		p.distance = 0.0
		p.touching_edge = 0
	phase = RUNNING
	camera_y = 0.0
	gap_scale = 1.0
	stage_ticks = 0
	winner = NO_WINNER
	events = 0
	traffic = []
	spawner = _versus_spawner()
	for b: Bot in bots:
		b.reset()


## Seat 0, the single player.
func player() -> Car:
	return players[0]


## Screen y of a world y: top = anchor + (camera_y - y_world).
func screen_y(y_world: float) -> float:
	return anchor + (camera_y - y_world)


## Advances one tick. One byte per seat (player_input.gd); a missing byte reads as no input, and 0xFF means a bot
## drives the seat. Single player: pause and confirm come from any seat that is not a bot. Versus: _step_versus().
func step(inputs: PackedByteArray) -> void:
	tick += 1
	events = 0
	for p: Car in players:
		p.events = 0
	if mode == MODE_VERSUS:
		_step_versus(inputs)
		return

	var bytes := PackedByteArray()
	bytes.resize(players.size())
	var pause_pressed := false
	var confirm_pressed := false
	for p: Car in players:
		var byte := PlayerInput.NONE
		if p.slot < inputs.size():
			byte = inputs[p.slot]
		if PlayerInput.is_bot(byte):
			byte = _bot_byte(p)
		else:
			pause_pressed = pause_pressed or PlayerInput.pause(byte)
			confirm_pressed = confirm_pressed or PlayerInput.confirm(byte)
		bytes[p.slot] = byte

	if phase == GAME_OVER:
		return
	if phase == STAGE_CLEAR:
		if confirm_pressed:
			_next_stage()
		return
	if phase == PAUSED:
		if pause_pressed:
			phase = RUNNING
			events = EV_RESUME
		return
	if pause_pressed:
		phase = PAUSED
		events = EV_PAUSE
		return

	_run(bytes)
	for p: Car in players:
		events |= p.events


## A versus step. Only human seats pause, and never with the bot byte: a pause press from any human seat pauses a
## running round and resumes a paused one; a non-human seat's byte never pauses. The world takes no confirm press,
## and no input at all once the round is over. On a step that runs, and only then, each live seat whose byte is
## 0xFF gets its byte from _bot_byte(), once, in seat order, before anything moves: never while paused, on the step
## that pauses or resumes, or after the round. So a bot that draws random numbers or keeps a reaction delay sees
## exactly the running steps, however long the game is paused.
func _step_versus(inputs: PackedByteArray) -> void:
	var bytes := PackedByteArray()
	bytes.resize(players.size())
	var bot_mask := 0
	var pause_pressed := false
	for p: Car in players:
		var byte := PlayerInput.NONE
		if p.slot < inputs.size():
			byte = inputs[p.slot]
		if PlayerInput.is_bot(byte):
			bot_mask |= 1 << p.slot
			byte = PlayerInput.NONE
		elif p.human != 0:
			pause_pressed = pause_pressed or PlayerInput.pause(byte)
		bytes[p.slot] = byte

	if phase == ROUND_OVER:
		return
	if phase == PAUSED:
		if pause_pressed:
			phase = RUNNING
			events = EV_RESUME
		return
	if pause_pressed:
		phase = PAUSED
		events = EV_PAUSE
		return

	for p: Car in players:
		if p.alive != 0 and (bot_mask & (1 << p.slot)) != 0:
			bytes[p.slot] = _bot_byte(p)
	_run(bytes)
	for p: Car in players:
		events |= p.events


## The byte of a seat whose input byte is 0xFF. Versus: the seat's bot picks it from this world (Bot.next_byte()),
## so a bot or a bot takeover replays exactly; _step_versus() asks only on running steps, once per live 0xFF seat, in
## seat order. Single player: no input, as in A1 (it asks on every step, paused or not, and has no bots).
func _bot_byte(car: Car) -> int:
	if mode != MODE_VERSUS:
		return PlayerInput.NONE
	return bots[car.slot].next_byte(cfg, car, players, traffic, camera_y + anchor, stage_ticks)


## One running step, in the order of Phaser's runStep(). The RNG draws happen in the same order, so the phaser
## profile replays Phaser's games. Versus adds steps 2b, 5a, 7 and 8, and ends the step its own way.
func _run(bytes: PackedByteArray) -> void:
	var versus_mode := mode == MODE_VERSUS
	var prev_y := PackedFloat64Array()
	var scrolls := PackedFloat64Array()
	prev_y.resize(players.size())
	scrolls.resize(players.size())

	# 1. Cars: gear is held, speed follows the throttle, lateral motion covers steering, skids and the roadside.
	#    Fuel drains while running. Roadside contact is a crash. Then invulnerability counts down.
	for p: Car in players:
		prev_y[p.slot] = p.y_world
		if p.alive == 0:
			continue
		var byte := bytes[p.slot]
		p.gear = Car.GEAR_HIGH if PlayerInput.high_gear(byte) else Car.GEAR_LOW
		p.speed = Car.step_speed(p.speed, p.gear, PlayerInput.accel(byte), PlayerInput.brake(byte))
		var hit_roadside := Car.step_lateral(cfg, p, PlayerInput.steer_of(byte))
		p.fuel = Fuel.drain(p.fuel)
		if hit_roadside and p.invulnerable <= 0:
			Car.apply_crash(p)
			p.fuel = Fuel.apply_crash(p.fuel, _seat_rng(p))
			p.events |= EV_SPIN | EV_CRASH
		Car.tick_invulnerable(p)
		# 2. Road distance.
		var scroll := p.speed * cfg.px_per_kmh * Config.DT
		scrolls[p.slot] = scroll
		p.y_world += scroll
	var camera_before := camera_y
	var road_scroll := _advance_camera(prev_y, scrolls)
	# 2b. Versus: the bottom edge, and distance points.
	if versus_mode:
		_bottom_edge(camera_y - camera_before, scrolls)

	# 3. Traffic: own motion, lane changes, passing, leaving the screen.
	_step_traffic()
	# 4. New traffic, by road scrolled.
	_advance_spawner(road_scroll)

	# 5. Contacts with traffic. A truck puts the seat out. 5a. Versus: each fuel car first, to the nearest seat.
	if versus_mode:
		_award_fuel_cars()
	var out_mask := 0
	for p: Car in players:
		if p.alive != 0 and _collide(p):
			out_mask |= 1 << p.slot
	# 6. So does an empty tank.
	for p: Car in players:
		if p.alive != 0 and Fuel.is_empty(p.fuel):
			out_mask |= 1 << p.slot
	# 7. Versus: every seat out this step leaves at once, before oil patches count who is left.
	if versus_mode:
		_eliminate(out_mask)
	_remove_consumed()
	stage_ticks += 1

	if versus_mode:
		# 8. Denser traffic: car and oil gaps x VERSUS_GAP_SHRINK every VERSUS_SHRINK_TICKS running ticks.
		if stage_ticks % Config.VERSUS_SHRINK_TICKS == 0:
			gap_scale *= Config.VERSUS_GAP_SHRINK
		_end_versus_step(out_mask)
	else:
		_end_stages_step(out_mask)


## The RNG a seat's own random events draw from (oil-skid direction, roadside crash cost, centre-bump direction):
## the seat's stream in versus mode, the world's in single player, as Phaser did, so the golden traces hold.
func _seat_rng(p: Car) -> Rng:
	return p.rng if mode == MODE_VERSUS else rng


## Single-player end of step: game over beats stage clear (docs/PLAN.md §4 "Priority within one step").
func _end_stages_step(out_mask: int) -> void:
	if out_mask != 0:
		events |= EV_GAME_OVER
		phase = GAME_OVER
		_update_high_score()
		return
	for p: Car in players:
		if p.alive != 0 and p.y_world >= goal:
			events |= EV_STAGE_CLEAR
			phase = STAGE_CLEAR
			for q: Car in players:
				q.score += Fuel.stage_clear_bonus(q.fuel)
			_update_high_score()
			return
	_update_high_score()


func _update_high_score() -> void:
	for p: Car in players:
		high_score = maxi(high_score, p.score)


## Moves the camera up to the leading live car (it never moves back) and returns the road scrolled this step.
## When the camera car drove on from the camera line, that is exactly its own scroll, as in Phaser.
func _advance_camera(prev_y: PackedFloat64Array, scrolls: PackedFloat64Array) -> float:
	var leader := _leader()
	if leader == null:
		return 0.0
	var before := camera_y
	if leader.y_world <= before:
		return 0.0
	camera_y = leader.y_world
	if prev_y[leader.slot] == before:
		return scrolls[leader.slot]
	return camera_y - before


## The live car furthest ahead; the lowest seat wins a tie. null when no car is alive.
func _leader() -> Car:
	var best: Car = null
	for p: Car in players:
		if p.alive != 0 and (best == null or p.y_world > best.y_world):
			best = p
	return best


func _alive_mask() -> int:
	var mask := 0
	for p: Car in players:
		if p.alive != 0:
			mask |= 1 << p.slot
	return mask


## Versus: the bottom edge pushes (docs/GODOT_PLAN.md §7). A live car whose bottom edge would end the step below
## screen y cfg.edge_bottom is put back on it, and its speed becomes at least the camera's speed this step
## (camera_moved / (K x dt)), so it keeps up and can still steer. A car held there, or whose bottom edge is at
## cfg.edge_touch or lower, touches the edge: it loses EDGE_FUEL_DRAIN_PER_SEC more fuel and earns no distance (here)
## or pass points (_step_traffic()). Any other live car adds its own scroll (speed x K x dt) to its distance and
## earns VERSUS_DISTANCE_POINTS for every whole cfg.distance_step px of distance.
func _bottom_edge(camera_moved: float, scrolls: PackedFloat64Array) -> void:
	for p: Car in players:
		if p.alive == 0:
			continue
		var lowest := camera_y + anchor + p.h - cfg.edge_bottom
		var held := p.y_world < lowest
		if held:
			p.y_world = lowest
			p.speed = maxf(p.speed, camera_moved / (cfg.px_per_kmh * Config.DT))
		p.touching_edge = 1 if held or screen_y(p.y_world) + p.h >= cfg.edge_touch else 0
		if p.touching_edge != 0:
			p.fuel = maxf(0.0, p.fuel - Config.EDGE_FUEL_DRAIN_PER_SEC * Config.DT)
			continue
		var paid := floori(p.distance / cfg.distance_step)
		p.distance += scrolls[p.slot]
		p.score += (floori(p.distance / cfg.distance_step) - paid) * Config.VERSUS_DISTANCE_POINTS


## Phaser's stepTraffic(): each object moves at its own speed, red and blue cars change lanes, passed cars pay 50
## once per seat, and objects that leave the screen are dropped. Versus: a seat touching the bottom edge uses up the
## pass but is not paid.
func _step_traffic() -> void:
	var kept: Array[Traffic] = []
	for c: Traffic in traffic:
		c.y_world += c.kmh * cfg.px_per_kmh * Config.DT

		if c.target_lane < 0 and c.lanes_left > 0 and c.is_car():
			c.lane_timer -= 1
			if c.lane_timer <= 0:
				var current := Traffic.lane_of(cfg, c.x, c.w)
				var target := _lane_target(c, current)
				if target != current:
					c.target_lane = target
					c.lanes_left -= 1
				c.lane_timer = Traffic.ticks_for(rng.float_range(Config.LANE_TIMER_NEXT_MIN, Config.LANE_TIMER_NEXT_MAX))
		if c.target_lane >= 0:
			var target_x := Traffic.lane_x(cfg, c.target_lane, c.w)
			var move := cfg.lane_change_speed * Config.DT
			var delta := target_x - c.x
			if absf(delta) <= move:
				c.x = target_x
				c.target_lane = -1
			else:
				c.x += signf(delta) * move

		# Passed: the object's front edge is behind the car's rear edge. Oil and fuel cars never pay.
		if c.is_car():
			for p: Car in players:
				var bit := 1 << p.slot
				if p.alive != 0 and (c.passed_mask & bit) == 0 and c.y_world < p.y_world - p.h:
					c.passed_mask |= bit
					if mode == MODE_VERSUS and p.touching_edge != 0:
						continue
					p.score += Config.POINTS_PER_PASSED_CAR
					p.events |= EV_PASS

		var top := screen_y(c.y_world)
		var off_bottom := top > cfg.view_height + cfg.off_bottom
		var off_top := top + c.h < -cfg.off_top
		if not off_bottom and not off_top:
			kept.append(c)
	traffic = kept


## Lane for a lane change. A blue car near a seat heads for that seat's lane; otherwise a random other lane.
## The standard profile only allows adjacent lanes (docs/GODOT_PLAN.md §4). Versus draws the random lane first, every
## time, even when a blue car then heads for a seat instead: so the world RNG's draws do not depend on where the
## seats are, and adding seats or bots does not shift the traffic.
func _lane_target(c: Traffic, current: int) -> int:
	if mode == MODE_VERSUS:
		var random_lane := _random_lane(current)
		var toward := _toward_blue_target(c, current)
		return random_lane if toward < 0 else toward
	var toward_seat := _toward_blue_target(c, current)
	if toward_seat >= 0:
		return toward_seat
	return _random_lane(current)


## The lane a blue car moves to when a seat draws it, or -1: not blue, no seat within reach, or already in the
## seat's lane.
func _toward_blue_target(c: Traffic, current: int) -> int:
	if c.kind != Config.KIND_BLUE:
		return -1
	var target_car := _blue_target(c)
	if target_car == null:
		return -1
	var player_lane := Traffic.lane_of(cfg, target_car.x, target_car.w)
	if player_lane == current:
		return -1
	if cfg.adjacent_lanes != 0:
		return current + (1 if player_lane > current else -1)
	return player_lane


## A random lane other than `current` (an adjacent one in the standard profile). One world-RNG draw.
func _random_lane(current: int) -> int:
	var options: Array[int] = []
	for lane in cfg.lane_count:
		if lane != current and (cfg.adjacent_lanes == 0 or absi(lane - current) == 1):
			options.append(lane)
	return options[rng.pick_index(options.size())]


## The seat a blue car reacts to: the car overlaps the band from the seat's rear edge to blue_reach ahead of its
## front edge. Single player: the first such seat in seat order (the player). Versus: of the live seats in reach,
## the one whose centre is nearest the blue car's in y; the lowest seat on a tie (docs/GODOT_PLAN.md §7).
func _blue_target(c: Traffic) -> Car:
	var best: Car = null
	var best_distance := 0.0
	for p: Car in players:
		if p.alive != 0 and c.y_world - c.h < p.y_world + cfg.blue_reach and c.y_world > p.y_world - p.h:
			if mode != MODE_VERSUS:
				return p
			var distance := absf((c.y_world - c.h / 2.0) - (p.y_world - p.h / 2.0))
			if best == null or distance < best_distance:
				best = p
				best_distance = distance
	return best


## Phaser's advanceSpawner(): each gap counts down by the road scrolled; at 0 an object spawns in a free lane.
## A gap that cannot spawn (every lane busy) stays at 0 and retries next step.
func _advance_spawner(scroll: float) -> void:
	spawner.car_gap -= scroll
	if spawner.car_gap <= 0.0:
		if _try_spawn(Traffic.pick_car_kind(rng)):
			spawner.car_gap += _next_gap(Config.GAP_CAR)
		else:
			spawner.car_gap = 0.0
	spawner.oil_gap -= scroll
	if spawner.oil_gap <= 0.0:
		if _try_spawn(Config.KIND_OIL):
			spawner.oil_gap += _next_gap(Config.GAP_OIL)
		else:
			spawner.oil_gap = 0.0
	spawner.fuel_gap -= scroll
	if spawner.fuel_gap <= 0.0:
		if _try_spawn(Config.KIND_FUEL_CAR):
			spawner.fuel_gap += _next_gap(Config.GAP_FUEL)
		else:
			spawner.fuel_gap = 0.0


## The next spawn gap of a kind, one world-RNG draw: Traffic.next_gap() with the stage's gap_scale, or versus_gap()
## in versus mode.
func _next_gap(gap_kind: int) -> float:
	if mode == MODE_VERSUS:
		return versus_gap(cfg, gap_kind, gap_scale, rng)
	return Traffic.next_gap(cfg, gap_kind, gap_scale, rng)


## Versus spawn gap of a kind (Config.GAP_CAR, GAP_OIL or GAP_FUEL) in px of road: the car and oil gaps of
## Traffic.next_gap() x p_gap_scale, never below p_cfg.versus_gap_min (single player's car_gap_min does not apply);
## fuel-car gaps as at the start, whatever the scale. One draw from p_rng, as next_gap().
static func versus_gap(p_cfg: Config, gap_kind: int, p_gap_scale: float, p_rng: Rng) -> float:
	if gap_kind == Config.GAP_FUEL:
		return Traffic.next_gap(p_cfg, gap_kind, 1.0, p_rng)
	var base := p_cfg.car_gap
	var jitter := p_cfg.car_gap_jitter
	if gap_kind == Config.GAP_OIL:
		base = p_cfg.oil_gap
		jitter = p_cfg.oil_gap_jitter
	return maxf((base + p_rng.float_range(-jitter, jitter)) * p_gap_scale, p_cfg.versus_gap_min)


## A versus round's spawner: the first car comes after half a gap, as in Traffic.create_spawner(). Three world-RNG
## draws: car, oil, fuel.
func _versus_spawner() -> Traffic.Spawner:
	var s := Traffic.Spawner.new()
	s.car_gap = versus_gap(cfg, Config.GAP_CAR, gap_scale, rng) / 2.0
	s.oil_gap = versus_gap(cfg, Config.GAP_OIL, gap_scale, rng)
	s.fuel_gap = versus_gap(cfg, Config.GAP_FUEL, gap_scale, rng)
	s.next_id = 1
	return s


## Adds one object just above the screen in a lane with nothing near the top. False if every lane is busy.
func _try_spawn(kind: int) -> bool:
	var free: Array[int] = []
	for lane in cfg.lane_count:
		var busy := false
		for c: Traffic in traffic:
			if screen_y(c.y_world) < cfg.spawn_busy_y and Traffic.lane_of(cfg, c.x, c.w) == lane:
				busy = true
				break
		if not busy:
			free.append(lane)
	if free.is_empty():
		return false

	var lane := free[rng.pick_index(free.size())]
	var c := Traffic.new()
	c.id = spawner.next_id
	c.kind = kind
	c.w = cfg.kind_w[kind]
	c.h = cfg.kind_h[kind]
	c.x = Traffic.lane_x(cfg, lane, c.w)
	# Screen top at -h - spawn_above.
	c.y_world = camera_y + anchor + c.h + cfg.spawn_above
	c.kmh = Traffic.own_speed(kind, rng)
	c.target_lane = -1
	c.lanes_left = Traffic.lanes_to_change(kind, rng)
	c.lane_timer = Traffic.ticks_for(rng.float_range(Config.LANE_TIMER_FIRST_MIN, Config.LANE_TIMER_FIRST_MAX))
	traffic.append(c)
	spawner.next_id += 1
	return true


## Versus: each fuel car that live seats touch this step goes to the one whose centre is nearest the fuel car's
## centre (straight-line distance), the lowest seat on a tie: +FUEL_PICKUP fuel, +FUEL_CAR_POINTS, EV_PICKUP. It is
## settled before the other contacts, so a seat that meets a truck in the same step still has the pickup, which
## counts when the round's winner is chosen.
func _award_fuel_cars() -> void:
	for c: Traffic in traffic:
		if c.kind != Config.KIND_FUEL_CAR or c.consumed_mask != 0:
			continue
		var centre_x := c.x + c.w / 2.0
		var centre_y := c.y_world - c.h / 2.0
		var best: Car = null
		var best_distance := 0.0
		for p: Car in players:
			if p.alive == 0 or not Collision.overlaps(p.x, -p.y_world, p.w, p.h, c.x, -c.y_world, c.w, c.h):
				continue
			var dx := p.x + p.w / 2.0 - centre_x
			var dy := p.y_world - p.h / 2.0 - centre_y
			var distance := dx * dx + dy * dy
			if best == null or distance < best_distance:
				best = p
				best_distance = distance
		if best != null:
			c.consumed_mask = 1 << best.slot
			best.fuel = Fuel.collect(best.fuel)
			best.score += Config.FUEL_CAR_POINTS
			best.events |= EV_PICKUP


## Contacts between one car and the traffic, in traffic order (Phaser's runStep() step 4). Returns true when a
## truck puts the car out. Cars never touch each other: only traffic is checked.
func _collide(p: Car) -> bool:
	var bit := 1 << p.slot
	for c: Traffic in traffic:
		if _consumed_for(c, bit):
			continue
		if not Collision.overlaps(p.x, -p.y_world, p.w, p.h, c.x, -c.y_world, c.w, c.h):
			continue

		if c.kind == Config.KIND_OIL:
			c.consumed_mask |= bit
			if not p.is_skidding():
				Car.start_skid(cfg, p, -1 if _seat_rng(p).next() < 0.5 else 1)
				p.events |= EV_SKID
			continue

		if c.kind == Config.KIND_FUEL_CAR:
			c.consumed_mask |= bit
			p.fuel = Fuel.collect(p.fuel)
			p.score += Config.FUEL_CAR_POINTS
			p.events |= EV_PICKUP
			continue

		if p.invulnerable > 0:
			continue

		if c.kind == Config.KIND_TRUCK:
			return true

		# Yellow, red and blue: a bump, at most once per car and seat. No fuel or speed is lost.
		if (c.struck_mask & bit) != 0:
			continue
		c.struck_mask |= bit
		var own_centre := p.x + p.w / 2.0
		var other_centre := c.x + c.w / 2.0
		var away := 0
		if own_centre == other_centre:
			away = -1 if _seat_rng(p).next() < 0.5 else 1
		else:
			away = -1 if own_centre < other_centre else 1
		Car.apply_bump(cfg, p, away)
		p.events |= EV_BUMP
	return false


## Oil acts once per seat. A fuel car belongs to whoever collects it first.
func _consumed_for(c: Traffic, bit: int) -> bool:
	if c.kind == Config.KIND_OIL:
		return (c.consumed_mask & bit) != 0
	if c.kind == Config.KIND_FUEL_CAR:
		return c.consumed_mask != 0
	return false


## A collected fuel car leaves the road; an oil patch leaves once every live seat has driven over it.
func _remove_consumed() -> void:
	var alive_mask := _alive_mask()
	var kept: Array[Traffic] = []
	for c: Traffic in traffic:
		if c.kind == Config.KIND_FUEL_CAR and c.consumed_mask != 0:
			continue
		if c.kind == Config.KIND_OIL and c.consumed_mask != 0 and (c.consumed_mask & alive_mask) == alive_mask:
			continue
		kept.append(c)
	traffic = kept


## Versus: the seats in out_mask leave the round together (alive 0, EV_OUT). An eliminated car stays in `players`
## (seats keep their index) but is no longer moved, drawn, collided, pushed or followed by the camera.
func _eliminate(out_mask: int) -> void:
	for p: Car in players:
		if (out_mask & (1 << p.slot)) != 0:
			p.alive = 0
			p.touching_edge = 0
			p.events |= EV_OUT


## Versus end of step: a human seat out (also one a bot drives after a disconnect) ends the round; with a single
## human seat, so does the last bot out. The step's eliminations are all applied by now, so the winner is chosen on
## the state after every one of them.
func _end_versus_step(out_mask: int) -> void:
	var humans := 0
	var bots_alive := 0
	var human_out := false
	for p: Car in players:
		if p.human != 0:
			humans += 1
			human_out = human_out or (out_mask & (1 << p.slot)) != 0
		elif p.alive != 0:
			bots_alive += 1
	if not human_out and not (humans == 1 and bots_alive == 0):
		return
	phase = ROUND_OVER
	events |= EV_ROUND_OVER
	winner = _round_winner(out_mask)


## The round's winner (docs/GODOT_PLAN.md §7), a human seat or NO_WINNER. Candidates: the human seats still alive
## or, when none is, the human seats that went out this step (out_mask). The best has the most points, then the
## most distance, then the most fuel; if it is level with another candidate on all three, nobody wins. With a
## single human seat, that human must also beat every bot still alive on points, then distance. Bots never win.
func _round_winner(out_mask: int) -> int:
	var candidates: Array[Car] = []
	for p: Car in players:
		if p.human != 0 and p.alive != 0:
			candidates.append(p)
	if candidates.is_empty():
		for p: Car in players:
			if p.human != 0 and (out_mask & (1 << p.slot)) != 0:
				candidates.append(p)
	var best: Car = null
	var level := false
	for p: Car in candidates:
		if best == null:
			best = p
			continue
		var order := _rank(p, best, true)
		if order > 0:
			best = p
			level = false
		elif order == 0:
			level = true
	if best == null or level:
		return NO_WINNER
	var humans := 0
	for p: Car in players:
		humans += p.human
	if humans == 1:
		for p: Car in players:
			if p.human == 0 and p.alive != 0 and _rank(best, p, false) <= 0:
				return NO_WINNER
	return best.slot


## 1 if `a` ranks above `b`, -1 if below, 0 if level: more points, then more distance, then (with_fuel) more fuel.
static func _rank(a: Car, b: Car, with_fuel: bool) -> int:
	if a.score != b.score:
		return 1 if a.score > b.score else -1
	if a.distance != b.distance:
		return 1 if a.distance > b.distance else -1
	if with_fuel and a.fuel != b.fuel:
		return 1 if a.fuel > b.fuel else -1
	return 0


## Confirm at stage clear: next stage with full tanks, an empty road, a longer goal and shorter spawn gaps.
## Score, speed, gear, x, skid and invulnerability carry over, as in Phaser's nextStage().
func _next_stage() -> void:
	stage += 1
	phase = RUNNING
	gap_scale *= Config.SPAWN_GAP_SCALE
	goal = cfg.stage_goal(stage)
	for p: Car in players:
		p.fuel = Config.FUEL_MAX
		p.y_world = 0.0
	camera_y = 0.0
	traffic = []
	spawner = Traffic.create_spawner(cfg, gap_scale, rng)
	stage_ticks = 0


## Every field of the state, as plain ints, floats and arrays: [FORMAT, profile, rng state, SCALARS...,
## spawner, seats, traffic, bots]. Floats are never turned into text.
func to_array() -> Array:
	var a: Array = [FORMAT, cfg.profile, rng.state]
	for field: String in SCALARS:
		a.append(get(field))
	a.append(spawner.to_array())
	var seats: Array = []
	for p: Car in players:
		seats.append(p.to_array())
	a.append(seats)
	var objects: Array = []
	for c: Traffic in traffic:
		objects.append(c.to_array())
	a.append(objects)
	var drivers: Array = []
	for b: Bot in bots:
		drivers.append(b.to_array())
	a.append(drivers)
	return a


## Rebuilds a world from to_array(). p_cfg must be the profile the array was made with.
static func from_array(p_cfg: Config, a: Array) -> Self:
	if a.size() != 7 + SCALARS.size() or a[0] != FORMAT or a[1] != p_cfg.profile:
		push_error("World.from_array: wrong format or profile")
		return null
	var w := Self.new(p_cfg, 0, 0)
	w.rng.state = a[2]
	for i in SCALARS.size():
		w.set(SCALARS[i], a[3 + i])
	w.spawner = Traffic.Spawner.from_array(a[3 + SCALARS.size()])
	for seat: Array in a[4 + SCALARS.size()]:
		w.players.append(Car.from_array(seat))
	for object: Array in a[5 + SCALARS.size()]:
		w.traffic.append(Traffic.from_array(object))
	for driver: Array in a[6 + SCALARS.size()]:
		w.bots.append(Bot.from_array(driver))
	return w


## SHA-256 of the serialised state. Two worlds with the same checksum are the same world.
func checksum() -> String:
	return var_to_bytes(to_array()).hex_encode().sha256_text()


func clone() -> Self:
	var w := Self.new(cfg, 0, 0)
	w.rng = rng.clone()
	for field: String in SCALARS:
		w.set(field, get(field))
	w.spawner = spawner.clone()
	for p: Car in players:
		w.players.append(p.clone())
	for c: Traffic in traffic:
		w.traffic.append(c.clone())
	for b: Bot in bots:
		w.bots.append(b.clone())
	return w
