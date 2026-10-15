extends RefCounted
## The whole simulation: seats (player cars), traffic, spawner, RNG, camera and phase, and step(), which advances
## it by one tick of 1/60 s (docs/GODOT_PLAN.md §3; src/game/state.ts in the Phaser version, commit 0a0841f).
##
## Pure and deterministic: no nodes, autoloads, engine singletons, clock or global RNG. The same seed and the same
## input bytes give the same world, bit for bit (checksum()).
##
## Coordinates: x is screen px (left edge of the hitbox). y_world grows forward, in world px; a car's front edge is
## at y_world. On screen, top = anchor + (camera_y - y_world): screen_y(). The camera is monotonic and follows the
## leading live car, which sits on the anchor line (292 in single-player). Per-seat traffic flags are bit masks.
##
## Single-player rules (mode MODE_STAGES) are the Phaser rules converted by K (config.gd). Phase B adds a versus
## mode (docs/GODOT_PLAN.md §7) next to it; the seat loops, masks and the bot byte (0xFF) are ready for it.

const Self := preload("res://scripts/sim/world.gd")
const Config := preload("res://scripts/sim/config.gd")
const Rng := preload("res://scripts/sim/rng.gd")
const Car := preload("res://scripts/sim/car.gd")
const Traffic := preload("res://scripts/sim/traffic.gd")
const Fuel := preload("res://scripts/sim/fuel.gd")
const Collision := preload("res://scripts/sim/collision.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")

## Layout version of to_array().
const FORMAT := 1

## Single-player stages: the Phaser game.
const MODE_STAGES := 0

## Phases.
const RUNNING := 0
const PAUSED := 1
const STAGE_CLEAR := 2
const GAME_OVER := 3
const PHASE_NAMES := ["running", "paused", "stage_clear", "game_over"]

## Events of the last step, as bits. Car.events holds a seat's own; World.events holds all of them plus the
## world-wide ones (stage clear, game over, pause, resume).
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
const EVENT_NAMES := ["skid", "bump", "crash", "spin", "pickup", "pass", "stage_clear", "game_over", "pause", "resume"]

## The scalar fields, in to_array() order. tests/test_world_state.gd checks that to_array() covers every field.
const SCALARS := [
	"game_seed", "mode", "tick", "phase", "stage", "goal", "gap_scale", "stage_ticks", "camera_y", "anchor",
	"high_score", "events"
]

var cfg: Config
var rng: Rng
## The seed this world started from. The RNG state moves on; this does not. Phase B seeds each bot's own RNG from
## it, and a new game after a game over can use game_seed + 1.
var game_seed: int = 0
var mode: int = MODE_STAGES
## Steps taken, in any phase.
var tick: int = 0
var phase: int = RUNNING
var stage: int = 1
## Distance to cover this stage, in world px.
var goal: float = 0.0
## Product of SPAWN_GAP_SCALE, once per stage after the first.
var gap_scale: float = 1.0
## Running ticks this stage (Phaser's `time`, in ticks).
var stage_ticks: int = 0
var camera_y: float = 0.0
## Screen y of the front edge of the car the camera follows.
var anchor: float = 0.0
## Best score this session. The caller passes it to the next World.
var high_score: int = 0
var events: int = 0
var players: Array[Car] = []
var traffic: Array[Traffic] = []
var spawner: Traffic.Spawner


## A new game: stage 1, full tanks, empty road. Every seat starts at the same place, in cfg.start_lane at
## y_world 0 (cars pass through each other; phase B chooses versus start lanes). Draws three RNG values (the
## spawner), as Phaser's createGame().
func _init(p_cfg: Config, p_seed: int, p_seats: int = 1, p_high_score: int = 0) -> void:
	cfg = p_cfg
	rng = Rng.new(p_seed)
	game_seed = p_seed & 0xFFFFFFFF
	high_score = p_high_score
	anchor = cfg.anchor_single
	goal = cfg.stage_goal(stage)
	for slot in p_seats:
		var car := Car.new()
		car.slot = slot
		car.w = cfg.player_w
		car.h = cfg.player_h
		car.x = Traffic.lane_x(cfg, cfg.start_lane, car.w)
		players.append(car)
	spawner = Traffic.create_spawner(cfg, gap_scale, rng)


## Seat 0, the single player.
func player() -> Car:
	return players[0]


## Screen y of a world y: top = anchor + (camera_y - y_world).
func screen_y(y_world: float) -> float:
	return anchor + (camera_y - y_world)


## Advances one tick. One byte per seat (player_input.gd); a missing byte reads as no input, and 0xFF means a bot
## drives the seat. Pause and confirm come from any seat that is not a bot.
func step(inputs: PackedByteArray) -> void:
	tick += 1
	events = 0
	for p: Car in players:
		p.events = 0

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


## Phase B: bot.gd picks the byte here, from this world, so a bot takeover replays exactly. Until then a bot seat
## gets no input.
func _bot_byte(_car: Car) -> int:
	return PlayerInput.NONE


## One running step, in the order of Phaser's runStep(). The RNG draws happen in the same order, so the phaser
## profile replays Phaser's games.
func _run(bytes: PackedByteArray) -> void:
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
			p.fuel = Fuel.apply_crash(p.fuel, rng)
			p.events |= EV_SPIN | EV_CRASH
		Car.tick_invulnerable(p)
		# 2. Road distance.
		var scroll := p.speed * cfg.px_per_kmh * Config.DT
		scrolls[p.slot] = scroll
		p.y_world += scroll
	var road_scroll := _advance_camera(prev_y, scrolls)

	# 3. Traffic: own motion, lane changes, passing, leaving the screen.
	_step_traffic()
	# 4. New traffic, by road scrolled.
	_advance_spawner(road_scroll)

	# 5. Contacts with traffic. A truck puts the seat out.
	var out_mask := 0
	for p: Car in players:
		if p.alive != 0 and _collide(p):
			out_mask |= 1 << p.slot
	# 6. So does an empty tank.
	for p: Car in players:
		if p.alive != 0 and Fuel.is_empty(p.fuel):
			out_mask |= 1 << p.slot
	_remove_consumed()
	stage_ticks += 1

	_end_stages_step(out_mask)


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


## Phaser's stepTraffic(): each object moves at its own speed, red and blue cars change lanes, passed cars pay 50
## once per seat, and objects that leave the screen are dropped.
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
					p.score += Config.POINTS_PER_PASSED_CAR
					p.events |= EV_PASS

		var top := screen_y(c.y_world)
		var off_bottom := top > cfg.view_height + cfg.off_bottom
		var off_top := top + c.h < -cfg.off_top
		if not off_bottom and not off_top:
			kept.append(c)
	traffic = kept


## Lane for a lane change. A blue car near a seat heads for that seat's lane; otherwise a random other lane.
## The standard profile only allows adjacent lanes (docs/GODOT_PLAN.md §4).
func _lane_target(c: Traffic, current: int) -> int:
	if c.kind == Config.KIND_BLUE:
		var target_car := _blue_target(c)
		if target_car != null:
			var player_lane := Traffic.lane_of(cfg, target_car.x, target_car.w)
			if player_lane != current:
				if cfg.adjacent_lanes != 0:
					return current + (1 if player_lane > current else -1)
				return player_lane
	var options: Array[int] = []
	for lane in cfg.lane_count:
		if lane != current and (cfg.adjacent_lanes == 0 or absi(lane - current) == 1):
			options.append(lane)
	return options[rng.pick_index(options.size())]


## The seat a blue car reacts to: the car overlaps the band from the seat's rear edge to blue_reach ahead of its
## front edge. Single-player: the player. Phase B picks the nearest live seat (docs/GODOT_PLAN.md §7).
func _blue_target(c: Traffic) -> Car:
	for p: Car in players:
		if p.alive != 0 and c.y_world - c.h < p.y_world + cfg.blue_reach and c.y_world > p.y_world - p.h:
			return p
	return null


## Phaser's advanceSpawner(): each gap counts down by the road scrolled; at 0 an object spawns in a free lane.
## A gap that cannot spawn (every lane busy) stays at 0 and retries next step.
func _advance_spawner(scroll: float) -> void:
	spawner.car_gap -= scroll
	if spawner.car_gap <= 0.0:
		if _try_spawn(Traffic.pick_car_kind(rng)):
			spawner.car_gap += Traffic.next_gap(cfg, Config.GAP_CAR, gap_scale, rng)
		else:
			spawner.car_gap = 0.0
	spawner.oil_gap -= scroll
	if spawner.oil_gap <= 0.0:
		if _try_spawn(Config.KIND_OIL):
			spawner.oil_gap += Traffic.next_gap(cfg, Config.GAP_OIL, gap_scale, rng)
		else:
			spawner.oil_gap = 0.0
	spawner.fuel_gap -= scroll
	if spawner.fuel_gap <= 0.0:
		if _try_spawn(Config.KIND_FUEL_CAR):
			spawner.fuel_gap += Traffic.next_gap(cfg, Config.GAP_FUEL, gap_scale, rng)
		else:
			spawner.fuel_gap = 0.0


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
				Car.start_skid(cfg, p, -1 if rng.next() < 0.5 else 1)
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
			away = -1 if rng.next() < 0.5 else 1
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
## spawner, seats, traffic]. Floats are never turned into text.
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
	return a


## Rebuilds a world from to_array(). p_cfg must be the profile the array was made with.
static func from_array(p_cfg: Config, a: Array) -> Self:
	if a.size() != 6 + SCALARS.size() or a[0] != FORMAT or a[1] != p_cfg.profile:
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
	return w
