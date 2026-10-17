extends RefCounted
## A bot: it drives one seat of a versus round (docs/GODOT_PLAN.md §7 "Bots"), one input byte per step, from the
## world it sees. World._bot_byte() asks the seat's bot (World.bots) on every running step whose byte for that seat is
## 0xFF: a bot's seat, or a human seat whose controller went away (the seat stays human). Pure and deterministic: the
## byte depends only on the world and the bot's own state, which World.to_array() keeps, so games with bots replay
## exactly.
##
## The rules of plan §7, as the bot applies them:
## - It always accelerates and never brakes.
## - It takes high gear from Config.BOT_HIGH_GEAR_KMH (160 km/h) while cfg.bot_free_ahead (150 px) of road ahead of
##   its car are free, and low gear otherwise.
## - It steers into a skid until the skid is over.
## - It chases a fuel car in its lane or the next one, up to cfg.bot_fuel_reach ahead, unless a truck is in the way.
## - Otherwise it heads for the clearest of its lane and the two next to it. A lane is as clear as the gap to its
##   first obstacle, at most cfg.bot_look_ahead. A truck counts cfg.bot_truck_caution nearer than it is, so a lane with
##   a truck near is worse than one where a car or oil is alongside: those bump or skid, a truck puts the car out.
##   Another player's car just ahead counts cfg.bot_player_ease further than it is: cars pass through each other, but
##   a bot gives way to the car ahead of it (to the lower seat when level), so bots spread over the road instead of
##   driving as one. It changes to a neighbouring lane only when that lane is cfg.bot_lane_margin clearer than the one
##   it is heading for; a tie between two neighbours is drawn from its own RNG.
## - It reacts Config.BOT_REACTION_TICKS (12) steps late: the byte it decides on one step drives the car 12 steps
##   later (next_byte()). It knows the bytes it has decided and not yet sent (`pending`), and plans from where they
##   will take the car, as a driver knows what their hands are already doing, so it does not steer past a lane.
##
## It sees what a player sees: traffic whose rear edge is below the top of the screen and whose front edge is ahead of
## its car's rear edge. It leaves out the cars that already bumped its seat and the oil its seat already drove over,
## which cannot touch it again.
##
## Its own RNG stream (World.bot_seed(): the game's seed and the seat) draws only to break those ties. So the bots
## never move the world RNG that makes the traffic, and nothing is drawn while a round is paused, since the world does
## not ask a bot for a byte then.

const Self := preload("res://scripts/sim/bot.gd")
const Config := preload("res://scripts/sim/config.gd")
const Rng := preload("res://scripts/sim/rng.gd")
const Car := preload("res://scripts/sim/car.gd")
const Traffic := preload("res://scripts/sim/traffic.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")

## The byte a bot starts each round with, for its first BOT_REACTION_TICKS steps: throttle, low gear, no steering.
const START_BYTE := PlayerInput.ACCEL | PlayerInput.STEER_NONE

## The bot's own stream. It continues from round to round.
var rng: Rng = Rng.new(0)
## The bytes decided and not yet sent, oldest first: always BOT_REACTION_TICKS of them.
var pending: Array[int] = []
## The lane the bot is heading for; -1 until it chooses one.
var lane: int = -1
## World.stage_ticks (the round's running steps) on the bot's last step this round; -1 when it has not driven yet.
var last_tick: int = -1


func _init(p_seed: int = 0) -> void:
	rng = Rng.new(p_seed)
	reset()


## A new round: START_BYTE for the reaction time, no lane chosen. The RNG goes on, as the world's does (plan §7).
func reset() -> void:
	_fill(START_BYTE)
	lane = -1
	last_tick = -1


## The byte that drives the seat on this step, from the world before the step: the byte decided BOT_REACTION_TICKS
## steps ago. This step's decision waits its turn in `pending`. players and traffic are the world's; round_tick is
## World.stage_ticks. A bot that did not drive the round's step before this one (a human seat whose controller has
## just gone away) first takes the car over (take_over()).
func next_byte(
	cfg: Config, car: Car, players: Array[Car], traffic: Array[Traffic], view_top: float, round_tick: int
) -> int:
	if last_tick != round_tick - 1:
		take_over(car)
	last_tick = round_tick
	pending.append(decide(cfg, car, players, traffic, view_top))
	return pending.pop_front()


## Takes a car over: until the bot has reacted, the car keeps the throttle and its present gear, and does not steer.
func take_over(car: Car) -> void:
	_fill(PlayerInput.encode(true, false, 0, car.gear == Car.GEAR_HIGH))
	lane = -1


## The byte the bot wants now; it drives the car BOT_REACTION_TICKS steps later. view_top is the world y of the top
## edge of the screen (World.camera_y + World.anchor). Sets `lane`, and may draw from `rng`.
func decide(cfg: Config, car: Car, players: Array[Car], traffic: Array[Traffic], view_top: float) -> int:
	var ghost := ahead_of_time(cfg, car)
	var ghost_x := ghost[0]
	var here := Traffic.lane_of(cfg, ghost_x, car.w)
	var first := maxi(here - 1, 0)
	var lanes := mini(here + 1, cfg.lane_count - 1) - first + 1
	# Each of the lanes first.. : where a car centred in it has its left edge (its corridor, with the side margin),
	# how clear it is, and the gap to its nearest truck.
	var corridor := PackedFloat64Array()
	var clear := PackedFloat64Array()
	var truck_at := PackedFloat64Array()
	for index in lanes:
		corridor.append(Traffic.lane_x(cfg, first + index, car.w))
		clear.append(cfg.bot_look_ahead)
		truck_at.append(INF)
	var side := cfg.bot_side_margin
	var free_ahead := INF
	var fuel_lane := -1
	var fuel_gap := INF
	var fuel_front := INF
	var bit := 1 << car.slot
	var rear := car.y_world - car.h
	for c: Traffic in traffic:
		var back := c.y_world - c.h
		if back >= view_top or c.y_world <= rear:
			continue
		# From the car's front edge to the object's rear edge; below 0 when they are side by side.
		var gap := back - car.y_world
		if c.kind == Config.KIND_FUEL_CAR:
			if c.consumed_mask == 0 and gap < cfg.bot_fuel_reach and gap < fuel_gap:
				var its_lane := Traffic.lane_of(cfg, c.x, c.w)
				if its_lane >= first and its_lane < first + lanes:
					fuel_lane = its_lane
					fuel_gap = gap
					fuel_front = gap + c.h
			continue
		if (c.kind == Config.KIND_OIL and (c.consumed_mask & bit) != 0) or (c.struck_mask & bit) != 0:
			continue
		# The road the object takes up: its own span and, while it changes lane, its target lane's.
		var left := c.x
		var right := c.x + c.w
		if c.target_lane >= 0:
			var to := Traffic.lane_x(cfg, c.target_lane, c.w)
			left = minf(left, to)
			right = maxf(right, to + c.w)
		if left < car.x + car.w + side and right > car.x - side:
			free_ahead = minf(free_ahead, gap)
		var truck := c.kind == Config.KIND_TRUCK
		var near := maxf(gap, 0.0) - (cfg.bot_truck_caution if truck else 0.0)
		for index in lanes:
			if left < corridor[index] + car.w + side and right > corridor[index] - side:
				clear[index] = minf(clear[index], near)
				if truck:
					truck_at[index] = minf(truck_at[index], gap)
	# Other players' cars: the one ahead (or level, of a lower seat) makes this one give way.
	for q: Car in players:
		if q == car or q.alive == 0 or q.y_world < car.y_world or (q.y_world == car.y_world and q.slot > car.slot):
			continue
		var eased := maxf((q.y_world - q.h) - car.y_world, 0.0) + cfg.bot_player_ease
		for index in lanes:
			if q.x < corridor[index] + car.w + side and q.x + q.w > corridor[index] - side:
				clear[index] = minf(clear[index], eased)

	var target := lane if lane >= first and lane < first + lanes else here
	if fuel_lane >= 0 and truck_at[fuel_lane - first] > fuel_front:
		target = fuel_lane
	else:
		var best := -INF
		var ties: Array[int] = []
		for index in lanes:
			var candidate := first + index
			if candidate == target:
				continue
			if clear[index] > best:
				best = clear[index]
				ties = [candidate]
			elif clear[index] == best:
				ties.append(candidate)
		if best > clear[target - first] + cfg.bot_lane_margin:
			target = ties[0] if ties.size() == 1 else ties[rng.pick_index(ties.size())]
	lane = target

	var steer := 0
	if ghost[1] != 0.0:
		steer = 1 if ghost[1] > 0.0 else -1
	else:
		var dx := corridor[target - first] - ghost_x
		if absf(dx) > Car.steer_rate(cfg, car.speed) * Config.DT / 2.0:
			steer = 1 if dx > 0.0 else -1
	var high := car.speed >= Config.BOT_HIGH_GEAR_KMH and free_ahead >= cfg.bot_free_ahead
	return PlayerInput.encode(true, false, steer, high)


## [x, slide_vx] of the car once the pending bytes have driven it: Car.step_lateral()'s rules, byte by byte, at the
## car's speed now (it hardly changes the steering rate in a reaction time), without what the bot cannot foresee
## (traffic, the bottom edge, a crash's slowdown).
func ahead_of_time(cfg: Config, car: Car) -> PackedFloat64Array:
	var x := car.x
	var slide := car.slide_vx
	var min_x := cfg.road_left
	var max_x := cfg.road_right - car.w
	var rate := Car.steer_rate(cfg, car.speed)
	var reduction := cfg.correction_accel * Config.DT
	for byte: int in pending:
		var bits := (byte & PlayerInput.STEER_MASK) >> PlayerInput.STEER_SHIFT
		var steer := -1 if bits == 0 else (1 if bits == 2 else 0)
		if slide != 0.0:
			var slid := x + slide * Config.DT
			var out := slid < min_x or slid > max_x
			if steer != 0 and (steer > 0) == (slide > 0.0) and not out:
				slide = 0.0 if absf(slide) <= reduction else slide - signf(slide) * reduction
			if out:
				slide = 0.0
			x = minf(maxf(slid, min_x), max_x)
		else:
			x = minf(maxf(x + float(steer) * rate * Config.DT, min_x), max_x)
	return PackedFloat64Array([x, slide])


func _fill(byte: int) -> void:
	pending.clear()
	for i in Config.BOT_REACTION_TICKS:
		pending.append(byte)


func clone() -> Self:
	var b := Self.new()
	b.rng = rng.clone()
	b.pending = pending.duplicate()
	b.lane = lane
	b.last_tick = last_tick
	return b


## [rng state, [pending bytes], lane, last_tick]: plain ints and a plain array (a typed one would serialise
## differently, and the checksum must not depend on where the state came from).
func to_array() -> Array:
	var bytes: Array = []
	bytes.append_array(pending)
	return [rng.state, bytes, lane, last_tick]


static func from_array(a: Array) -> Self:
	var b := Self.new()
	b.rng = Rng.new(a[0])
	b.pending.assign(a[1])
	b.lane = a[2]
	b.last_tick = a[3]
	return b
