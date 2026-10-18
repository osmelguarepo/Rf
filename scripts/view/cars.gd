extends Node2D
## Traffic and player cars, placed from World coordinates through the camera (drawTraffic and drawPlayer in
## src/render/draw.ts, Phaser version).
##
## Screen position. The simulation's screen top is World.screen_y(y_world) = anchor + camera_y - y_world, in float.
## The view rounds the camera and each y_world to whole pixels first (screen_top()), so the car on the camera is
## always exactly on the anchor line, and objects that stand on the road move with the road tiles (road.gd) pixel for
## pixel. The result is never more than 1 px from the rounded float position.
##
## Each sprite's body (its frame without the 1 px shadow) is centred on the hitbox: cars and oil land 1 px left of
## the hitbox (they are 2 px wider), skidding cars 6 px left and 1 px up.

const ViewConfig := preload("res://scripts/view/view_config.gd")
const Atlas := preload("res://scripts/view/atlas.gd")
const Draw := preload("res://scripts/view/draw.gd")
const PlayerColours := preload("res://scripts/view/player_colours.gd")
const Config := preload("res://scripts/sim/config.gd")
const World := preload("res://scripts/sim/world.gd")
const Car := preload("res://scripts/sim/car.gd")
const Traffic := preload("res://scripts/sim/traffic.gd")

var atlas: Atlas
var world: World
## Versus (B2): the seat of each world slot (the match's line-up), so every car is drawn in its seat's colour
## (player_colours.gd). Empty in single player, whose car is car_red.
var seat_colours: Array[int] = []


func setup(p_atlas: Atlas) -> void:
	atlas = p_atlas


func show_world(p_world: World) -> void:
	world = p_world
	queue_redraw()


## The camera's world y on whole pixels. road.gd scrolls by the same number.
static func camera_px(w: World) -> int:
	return floori(w.camera_y + 0.5)


## Screen y of a front edge, from the rounded camera and the rounded y_world.
static func screen_top(w: World, y_world: float) -> int:
	return floori(w.anchor) + camera_px(w) - floori(y_world + 0.5)


static func hitbox_pos(w: World, x: float, y_world: float) -> Vector2i:
	return Vector2i(floori(x + 0.5), screen_top(w, y_world))


## Blink rule: while invulnerable, the car is hidden on every other BLINK_TICKS ticks of the stage clock.
static func player_visible(car: Car, stage_ticks: int) -> bool:
	return not (car.invulnerable > 0 and floori(stage_ticks / float(ViewConfig.BLINK_TICKS)) % 2 == 0)


## The player's sprite: upright, or turned 45 degrees towards the slide while skidding.
static func player_sprite(car: Car) -> Dictionary:
	if car.slide_vx > 0.0:
		return ViewConfig.PLAYER_SKID_RIGHT
	if car.slide_vx < 0.0:
		return ViewConfig.PLAYER_SKID_LEFT
	return ViewConfig.PLAYER


## A seat's car sprite: player_sprite(), in the colour of its seat when `colours` (slot -> seat, versus) has one.
static func seat_car_sprite(car: Car, colours: Array[int]) -> Dictionary:
	if car.slot < colours.size():
		return PlayerColours.seat_sprite(player_sprite(car), colours[car.slot])
	return player_sprite(car)


## How a player car looks: {sprite (seat_car_sprite()), fallback (the flat colour drawn on its hitbox if the frame is
## missing: its seat's colour in versus, ViewConfig.PLAYER_FALLBACK in single player)}.
static func car_look(car: Car, colours: Array[int]) -> Dictionary:
	var fallback := ViewConfig.PLAYER_FALLBACK
	if car.slot < colours.size():
		fallback = PlayerColours.colour(colours[car.slot])
	return {"sprite": seat_car_sprite(car, colours), "fallback": fallback}


## The player cars _draw() draws, in slot order: each car on the road (alive, and not blinked off) as {slot, sprite,
## fallback (car_look()), box (its hitbox's top-left corner on screen), size (its hitbox's)}. _draw() draws exactly
## these, so the tests see which car is drawn where, and in which seat's colour.
static func car_draws(w: World, colours: Array[int]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for p: Car in w.players:
		if p.alive != 0 and player_visible(p, w.stage_ticks):
			var look := car_look(p, colours)
			look["slot"] = p.slot
			look["box"] = hitbox_pos(w, p.x, p.y_world)
			look["size"] = Vector2i(roundi(p.w), roundi(p.h))
			out.append(look)
	return out


## The fuel car's tint at a stage tick: a full trip round the hue circle every 1.5 s.
static func rainbow(stage_ticks: int) -> Color:
	return hue_colour(stage_ticks * ViewConfig.RAINBOW_DEGREES_PER_TICK)


## A hue in degrees as a colour at full saturation and value, each channel rounded to a byte (hueToColour in
## Phaser).
static func hue_colour(hue: float) -> Color:
	var h := fposmod(hue, 360.0)
	var section := floori(h / 60.0)
	var f := h / 60.0 - section
	var q := 1.0 - f
	var rgb: Array[float] = [1.0, f, 0.0]
	match section:
		1:
			rgb = [q, 1.0, 0.0]
		2:
			rgb = [0.0, 1.0, f]
		3:
			rgb = [0.0, q, 1.0]
		4:
			rgb = [f, 0.0, 1.0]
		5:
			rgb = [1.0, 0.0, q]
	return Color8(floori(rgb[0] * 255.0 + 0.5), floori(rgb[1] * 255.0 + 0.5), floori(rgb[2] * 255.0 + 0.5))


func _draw() -> void:
	if world == null:
		return
	var ticks := world.stage_ticks
	# Oil lies on the road, so it goes under every car.
	for c: Traffic in world.traffic:
		if c.kind == Config.KIND_OIL:
			_draw_traffic(c, Color.WHITE)
	for c: Traffic in world.traffic:
		if c.kind != Config.KIND_OIL:
			_draw_traffic(c, rainbow(ticks) if c.kind == Config.KIND_FUEL_CAR else Color.WHITE)
	for car: Dictionary in car_draws(world, seat_colours):
		Draw.sprite_on_hitbox(self, atlas, car["sprite"], car["box"], car["size"], car["fallback"])


func _draw_traffic(c: Traffic, modulate: Color) -> void:
	var box := hitbox_pos(world, c.x, c.y_world)
	var fallback: Color = ViewConfig.TRAFFIC_FALLBACK[c.kind]
	if c.kind == Config.KIND_FUEL_CAR:
		fallback = modulate
	Draw.sprite_on_hitbox(self, atlas, ViewConfig.TRAFFIC[c.kind], box, Vector2i(roundi(c.w), roundi(c.h)), fallback, modulate)
