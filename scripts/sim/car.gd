extends RefCounted
## A player's car, and the static rules that move it (src/game/car.ts in the Phaser version).
##
## x is the left edge of the hitbox in screen px. y_world is the front (top) edge in world px: the distance driven
## this stage in single-player mode. The car's screen top is World.screen_y(y_world).
##
## The fields from `human` on are the versus mode's (World.MODE_VERSUS, B1); single-player mode leaves them alone.

const Self := preload("res://scripts/sim/car.gd")
const Config := preload("res://scripts/sim/config.gd")
const Rng := preload("res://scripts/sim/rng.gd")

const GEAR_LOW := 0
const GEAR_NITRO := 1

## Seat index: the car's byte in World.step(inputs) and its bit (1 << slot) in the traffic masks.
var slot: int = 0
var x: float = 0.0
var y_world: float = 0.0
var w: float = 0.0
var h: float = 0.0
## km/h.
var speed: float = 0.0
var gear: int = GEAR_LOW
## Lateral slide speed in px/s while skidding; 0 when not skidding.
var slide_vx: float = 0.0
## Ticks of invulnerability left after a roadside crash or a bump.
var invulnerable: int = 0
var fuel: float = Config.FUEL_MAX
var score: int = 0
## 1 while the car takes part in the round. Single-player mode never clears it.
var alive: int = 1
## World.EV_* bits of the last step that concern this car.
var events: int = 0
## 1 for a person's seat, 0 for a bot's. Fixed when the world is made: a human seat that a bot drives after its
## controller went away (input byte 0xFF) still counts as human.
var human: int = 1
## Versus: px of world driven while not touching the bottom edge (speed x K x dt per step). Distance points are paid
## on it, and it breaks ties on points.
var distance: float = 0.0
## Versus: 1 if the car touched the bottom edge in the last running step (held on it, or its bottom edge at
## Config.edge_touch or lower). It then earns no pass or distance points and loses extra fuel.
var touching_edge: int = 0
## The seat's own RNG stream, seeded by World.seat_seed(). In versus mode the seat's oil-skid direction, roadside
## crash cost and centre-bump direction come from it, so a seat never moves the world RNG that makes the traffic.
## Single-player mode draws them from the world RNG, as Phaser did.
var rng: Rng = Rng.new(0)


func is_skidding() -> bool:
	return slide_vx != 0.0


## Top speed of a gear, km/h.
static func gear_top(p_gear: int) -> float:
	return Config.NITRO_TOP if p_gear == GEAR_NITRO else Config.LOW_GEAR_TOP


## Advances speed (km/h) by one step. Brake beats everything. Above the gear's top the car falls back at
## OVERSPEED_FALL. Otherwise the throttle accelerates (nitro is slow below 160 km/h); with no throttle it coasts.
static func step_speed(p_speed: float, p_gear: int, accel: bool, brake: bool) -> float:
	var top := gear_top(p_gear)
	if brake:
		return maxf(0.0, p_speed - Config.BRAKE * Config.DT)
	if p_speed > top:
		return maxf(top, p_speed - Config.OVERSPEED_FALL * Config.DT)
	if accel:
		var rate := Config.LOW_GEAR_ACCEL
		if p_gear == GEAR_NITRO:
			rate = Config.NITRO_SLOW_ACCEL if p_speed < Config.NITRO_SLOW_BELOW else Config.NITRO_ACCEL
		return minf(top, p_speed + rate * Config.DT)
	return maxf(0.0, p_speed - Config.DRAG * Config.DT)


## Lateral steering rate in px/s: zero while stopped, full from 30 km/h, slower at high speed.
static func steer_rate(cfg: Config, p_speed: float) -> float:
	if p_speed <= 0.0:
		return 0.0
	var full := minf(1.0, p_speed / Config.STEER_FULL_AT_KMH)
	return (cfg.steer_base - cfg.steer_per_kmh * p_speed) * full


## Moves the car sideways for one step and returns true if it reached the roadside (src/game/car.ts stepLateral).
##
## Normal driving: steering moves the car at steer_rate(speed).
## Skidding: steering does not move the car; the slide carries it at constant speed. Steering into the slide
## reduces the slide by correction_accel per second until it reaches 0. Steering against it, or not steering,
## leaves it unchanged. Either way the car is held at the edge, and a slide that reaches the edge stops.
static func step_lateral(cfg: Config, car: Self, steer: int) -> bool:
	var min_x := cfg.road_left
	var max_x := cfg.road_right - car.w
	if car.slide_vx != 0.0:
		var slid := car.x + car.slide_vx * Config.DT
		var slid_out := slid < min_x or slid > max_x
		var slide := car.slide_vx
		var into_slide := steer != 0 and signf(float(steer)) == signf(slide)
		if into_slide and not slid_out:
			var reduction := cfg.correction_accel * Config.DT
			slide = 0.0 if absf(slide) <= reduction else slide - signf(slide) * reduction
		if slid_out:
			slide = 0.0
		car.x = minf(maxf(slid, min_x), max_x)
		car.slide_vx = slide
		return slid_out
	var raw := car.x + float(steer) * steer_rate(cfg, car.speed) * Config.DT
	car.x = minf(maxf(raw, min_x), max_x)
	car.slide_vx = 0.0
	return raw < min_x or raw > max_x


## Starts a skid: direction -1 slides left, 1 slides right.
static func start_skid(cfg: Config, car: Self, direction: int) -> void:
	car.slide_vx = float(direction) * cfg.skid_speed


## Roadside crash: speed x 0.3, the skid ends, invulnerability starts. Fuel is handled by the caller.
static func apply_crash(car: Self) -> void:
	car.speed = car.speed * Config.CRASH_SPEED_FACTOR
	car.slide_vx = 0.0
	car.invulnerable = Config.INVULNERABLE_TICKS


## Car-on-car bump: no speed or fuel lost. A skid away from the other car, and invulnerability.
static func apply_bump(cfg: Config, car: Self, direction: int) -> void:
	start_skid(cfg, car, direction)
	car.invulnerable = Config.INVULNERABLE_TICKS


static func tick_invulnerable(car: Self) -> void:
	car.invulnerable = maxi(0, car.invulnerable - 1)


func clone() -> Self:
	var c := Self.new()
	c.slot = slot
	c.x = x
	c.y_world = y_world
	c.w = w
	c.h = h
	c.speed = speed
	c.gear = gear
	c.slide_vx = slide_vx
	c.invulnerable = invulnerable
	c.fuel = fuel
	c.score = score
	c.alive = alive
	c.events = events
	c.human = human
	c.distance = distance
	c.touching_edge = touching_edge
	c.rng = rng.clone()
	return c


## The RNG is its one u32 state.
func to_array() -> Array:
	return [
		slot, x, y_world, w, h, speed, gear, slide_vx, invulnerable, fuel, score, alive, events, human, distance,
		touching_edge, rng.state
	]


static func from_array(a: Array) -> Self:
	var c := Self.new()
	c.slot = a[0]
	c.x = a[1]
	c.y_world = a[2]
	c.w = a[3]
	c.h = a[4]
	c.speed = a[5]
	c.gear = a[6]
	c.slide_vx = a[7]
	c.invulnerable = a[8]
	c.fuel = a[9]
	c.score = a[10]
	c.alive = a[11]
	c.events = a[12]
	c.human = a[13]
	c.distance = a[14]
	c.touching_edge = a[15]
	c.rng = Rng.new(a[16])
	return c
