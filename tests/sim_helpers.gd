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
const ACCEL_HIGH := PlayerInput.ACCEL | PlayerInput.NITRO | PlayerInput.STEER_NONE
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
	quiet(w)
	return w


## A versus world (World.versus(); `humans` has bit 1 << seat for each human seat) whose spawner never fires.
static func quiet_versus(cfg: Config, seed_value: int, seats: int, humans: int) -> World:
	var w := World.versus(cfg, seed_value, seats, humans)
	quiet(w)
	return w


## Stops a world's spawner: nothing new comes onto the road. Also skips the start countdown of a race.
static func quiet(w: World) -> void:
	w.spawner.car_gap = INF
	w.spawner.oil_gap = INF
	w.spawner.fuel_gap = INF
	w.countdown = 0


## Puts a seat's car with its hitbox's top-left corner at screen (x, screen_top).
static func place(w: World, seat: int, x: float, screen_top: float) -> Car:
	var p := w.players[seat]
	p.x = x
	p.y_world = w.camera_y + w.anchor - screen_top
	return p


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


## Steps the world `times` times with one byte per seat, as given.
static func run_bytes(w: World, seat_bytes: Array, times: int = 1) -> void:
	var bytes := PackedByteArray(seat_bytes)
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


## A race round (World.is_race()) in which the car in `slot` is the first across the finish line now, the camera on it
## and every other car 60 px behind, as a real round has them: the others have not crossed, so the finish countdown
## starts.
static func arrive_alone(w: World, slot: int) -> void:
	var line := w.cfg.race_finish_px
	w.camera_y = line
	for p: Car in w.players:
		p.y_world = line if p.slot == slot else line - 60.0


## A race round that ends in the next step with `slot` the winner: that car is across the line, and every other car
## well over it, behind in the places in seat order (the camera on the line, so the bottom edge moves no one).
static func arrive(w: World, slot: int) -> void:
	var line := w.cfg.race_finish_px
	w.camera_y = line
	for p: Car in w.players:
		p.y_world = line + 3000.0 if p.slot == slot else line + 2000.0 - 100.0 * p.slot
