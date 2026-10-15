extends RefCounted
## Helpers shared by the simulation tests: input bytes, quiet worlds and traffic placed where a test needs it.
## Not a test file (the runner only runs tests/test_*.gd).

const Config := preload("res://scripts/sim/config.gd")
const World := preload("res://scripts/sim/world.gd")
const Traffic := preload("res://scripts/sim/traffic.gd")
const Car := preload("res://scripts/sim/car.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")

## Common input bytes (player_input.gd): NONE has the steer bits at "none"; a zero byte would steer left.
const NONE := PlayerInput.NONE
const ACCEL := PlayerInput.ACCEL | PlayerInput.STEER_NONE
const ACCEL_HIGH := PlayerInput.ACCEL | PlayerInput.HIGH_GEAR | PlayerInput.STEER_NONE
const BRAKE := PlayerInput.BRAKE | PlayerInput.STEER_NONE
const LEFT := PlayerInput.STEER_LEFT
const RIGHT := PlayerInput.STEER_RIGHT
const PAUSE := PlayerInput.PAUSE | PlayerInput.STEER_NONE
const CONFIRM := PlayerInput.CONFIRM | PlayerInput.STEER_NONE
## Ticks that keep a traffic car from starting a lane change during a test.
const NO_LANE_CHANGE := 1000000


## A world whose spawner never fires, so the road holds only what the test puts on it.
static func quiet_world(cfg: Config, seed_value: int = 1, seats: int = 1) -> World:
	var w := World.new(cfg, seed_value, seats)
	w.spawner.car_gap = INF
	w.spawner.oil_gap = INF
	w.spawner.fuel_gap = INF
	return w


## Adds a traffic object of a kind, its own size, with its top-left corner at screen (x, screen_top).
static func add_traffic(w: World, kind: int, x: float, screen_top: float, kmh: float = 0.0) -> Traffic:
	var c := Traffic.new()
	c.id = 900 + w.traffic.size()
	c.kind = kind
	c.w = w.cfg.kind_w[kind]
	c.h = w.cfg.kind_h[kind]
	c.x = x
	c.y_world = w.camera_y + w.anchor - screen_top
	c.kmh = kmh
	c.lane_timer = NO_LANE_CHANGE
	w.traffic.append(c)
	return c


## Adds a traffic object centred on a seat's car, standing still (the Phaser tests' onPlayer()).
static func on_car(w: World, kind: int, seat: int = 0) -> Traffic:
	var p := w.players[seat]
	var x := p.x + (p.w - w.cfg.kind_w[kind]) / 2.0
	var top := w.screen_y(p.y_world) + (p.h - w.cfg.kind_h[kind]) / 2.0
	return add_traffic(w, kind, x, top)


## Adds a traffic object centred in a lane, with its top at screen y.
static func in_lane(w: World, kind: int, lane: int, screen_top: float, kmh: float = 0.0) -> Traffic:
	return add_traffic(w, kind, Traffic.lane_x(w.cfg, lane, w.cfg.kind_w[kind]), screen_top, kmh)


## Steps the world `times` times with the same byte for every seat.
static func run(w: World, byte: int, times: int = 1) -> void:
	var bytes := PackedByteArray()
	bytes.resize(w.players.size())
	bytes.fill(byte)
	for i in times:
		w.step(bytes)


## A fresh car with a profile's player hitbox, outside any world.
static func car(cfg: Config, x: float, speed: float = 0.0) -> Car:
	var c := Car.new()
	c.w = cfg.player_w
	c.h = cfg.player_h
	c.x = x
	c.speed = speed
	return c


## The traffic object with this id, or null.
static func find(w: World, id: int) -> Traffic:
	for c: Traffic in w.traffic:
		if c.id == id:
			return c
	return null
