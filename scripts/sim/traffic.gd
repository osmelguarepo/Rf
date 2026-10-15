extends RefCounted
## One traffic object (car, truck, fuel car or oil patch), the spawner state, and the static traffic rules that do
## not need the whole world (src/game/traffic.ts in the Phaser version). world.gd moves, spawns and collides them.
##
## x is the left edge of the hitbox in screen px. y_world is the front (top) edge in world px; the screen top is
## World.screen_y(y_world). Per-seat flags are bit masks with bit (1 << slot) per seat.

const Self := preload("res://scripts/sim/traffic.gd")
const Config := preload("res://scripts/sim/config.gd")
const Rng := preload("res://scripts/sim/rng.gd")

var id: int = 0
var kind: int = Config.KIND_YELLOW
var x: float = 0.0
var y_world: float = 0.0
var w: float = 0.0
var h: float = 0.0
## The object's own forward speed in km/h. Oil patches are 0 (static on the road).
var kmh: float = 0.0
## Lane change in progress: the target lane, or -1.
var target_lane: int = -1
## Lane changes still to make.
var lanes_left: int = 0
## Ticks until the next lane change may start. Counts down only while lanes_left > 0 and no change is under way.
var lane_timer: int = 0
## Seats that have been paid for passing this car.
var passed_mask: int = 0
## Seats this car has already bumped (or tried to: a truck never sets it). It cannot bump them again.
var struck_mask: int = 0
## Oil: seats it has already sent into a skid. Fuel car: the seat that collected it.
var consumed_mask: int = 0


## Spawning is driven by road distance, not time: each gap counts down by the px of road scrolled.
class Spawner extends RefCounted:
	var car_gap: float = 0.0
	var oil_gap: float = 0.0
	var fuel_gap: float = 0.0
	## Id of the next object. Restarts at 1 with each stage, as in Phaser.
	var next_id: int = 1

	func clone() -> Spawner:
		var s := Spawner.new()
		s.car_gap = car_gap
		s.oil_gap = oil_gap
		s.fuel_gap = fuel_gap
		s.next_id = next_id
		return s

	func to_array() -> Array:
		return [car_gap, oil_gap, fuel_gap, next_id]

	static func from_array(a: Array) -> Spawner:
		var s := Spawner.new()
		s.car_gap = a[0]
		s.oil_gap = a[1]
		s.fuel_gap = a[2]
		s.next_id = a[3]
		return s


func is_car() -> bool:
	return kind != Config.KIND_OIL and kind != Config.KIND_FUEL_CAR


## Left edge of an object of width w centred in a lane.
static func lane_x(cfg: Config, lane: int, p_w: float) -> float:
	return cfg.road_left + float(lane) * cfg.lane_width + (cfg.lane_width - p_w) / 2.0


## Lane whose span holds the object's centre, clamped to the road.
static func lane_of(cfg: Config, p_x: float, p_w: float) -> int:
	var centre := p_x + p_w / 2.0
	var lane := floori((centre - cfg.road_left) / cfg.lane_width)
	return clampi(lane, 0, cfg.lane_count - 1)


## Ticks for a duration drawn in seconds: the steps Phaser's float countdown needed, ceil(seconds x 60).
static func ticks_for(seconds: float) -> int:
	return -floori(-seconds * float(Config.TICKS_PER_SECOND))


## Road distance until the next spawn of a kind (GAP_CAR, GAP_OIL, GAP_FUEL), scaled by the stage's gap_scale.
## Car gaps never go below car_gap_min. Always one RNG draw, even with no jitter.
static func next_gap(cfg: Config, gap_kind: int, gap_scale: float, rng: Rng) -> float:
	var base := cfg.car_gap
	var jitter := cfg.car_gap_jitter
	if gap_kind == Config.GAP_OIL:
		base = cfg.oil_gap
		jitter = cfg.oil_gap_jitter
	elif gap_kind == Config.GAP_FUEL:
		base = cfg.fuel_gap
		jitter = cfg.fuel_gap_jitter
	var gap := (base + rng.float_range(-jitter, jitter)) * gap_scale
	if gap_kind == Config.GAP_CAR:
		return maxf(gap, cfg.car_gap_min)
	return gap


## A fresh spawner for a stage: the first car comes after half a gap. Three RNG draws: car, oil, fuel.
static func create_spawner(cfg: Config, gap_scale: float, rng: Rng) -> Spawner:
	var s := Spawner.new()
	s.car_gap = next_gap(cfg, Config.GAP_CAR, gap_scale, rng) / 2.0
	s.oil_gap = next_gap(cfg, Config.GAP_OIL, gap_scale, rng)
	s.fuel_gap = next_gap(cfg, Config.GAP_FUEL, gap_scale, rng)
	s.next_id = 1
	return s


## Picks a car kind by Config.CAR_KIND_WEIGHTS. One RNG draw.
static func pick_car_kind(rng: Rng) -> int:
	var total := 0.0
	for weight: float in Config.CAR_KIND_WEIGHTS:
		total += weight
	var roll := rng.next() * total
	for i in Config.CAR_KIND_ORDER.size():
		roll -= Config.CAR_KIND_WEIGHTS[i]
		if roll < 0.0:
			return Config.CAR_KIND_ORDER[i]
	return Config.CAR_KIND_ORDER[Config.CAR_KIND_ORDER.size() - 1]


## Own speed of a new object, km/h. Yellow, red and blue draw it from the RNG.
static func own_speed(p_kind: int, rng: Rng) -> float:
	if p_kind == Config.KIND_YELLOW:
		return rng.float_range(Config.YELLOW_SPEED_MIN, Config.YELLOW_SPEED_MAX)
	if p_kind == Config.KIND_RED:
		return rng.float_range(Config.RED_SPEED_MIN, Config.RED_SPEED_MAX)
	if p_kind == Config.KIND_BLUE:
		return rng.float_range(Config.BLUE_SPEED_MIN, Config.BLUE_SPEED_MAX)
	if p_kind == Config.KIND_TRUCK:
		return Config.TRUCK_SPEED
	if p_kind == Config.KIND_FUEL_CAR:
		return Config.FUEL_CAR_SPEED
	return 0.0


## Lane changes a new object will make: red 1, blue 2-3 (one RNG draw), others 0.
static func lanes_to_change(p_kind: int, rng: Rng) -> int:
	if p_kind == Config.KIND_RED:
		return Config.RED_LANE_CHANGES
	if p_kind == Config.KIND_BLUE:
		return rng.int_range(Config.BLUE_LANE_CHANGES_MIN, Config.BLUE_LANE_CHANGES_MAX)
	return 0


func clone() -> Self:
	var c := Self.new()
	c.id = id
	c.kind = kind
	c.x = x
	c.y_world = y_world
	c.w = w
	c.h = h
	c.kmh = kmh
	c.target_lane = target_lane
	c.lanes_left = lanes_left
	c.lane_timer = lane_timer
	c.passed_mask = passed_mask
	c.struck_mask = struck_mask
	c.consumed_mask = consumed_mask
	return c


func to_array() -> Array:
	return [id, kind, x, y_world, w, h, kmh, target_lane, lanes_left, lane_timer, passed_mask, struck_mask, consumed_mask]


static func from_array(a: Array) -> Self:
	var c := Self.new()
	c.id = a[0]
	c.kind = a[1]
	c.x = a[2]
	c.y_world = a[3]
	c.w = a[4]
	c.h = a[5]
	c.kmh = a[6]
	c.target_lane = a[7]
	c.lanes_left = a[8]
	c.lane_timer = a[9]
	c.passed_mask = a[10]
	c.struck_mask = a[11]
	c.consumed_mask = a[12]
	return c
