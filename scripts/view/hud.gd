extends Node2D
## The game screen's HUD (render() in src/scenes/GameScene.ts, Phaser version), moved into the two side panels of
## the 16:9 screen: score, best, stage and the goal gauge on the left; speed, nitro, fuel and the fuel gauge on the
## right. Over the road: the short event messages, hidden while a panel is up. Over everything: the pause,
## stage-clear and game-over panels.
##
## Text is Press Start 2P at 8 and 16 px, at whole pixels. Numbers that change while driving (score, speed, fuel) are
## padded to a fixed width, so they do not shift sideways as digits come and go.
##
## Phase B (B2) replaces the two single-player panels with one panel per seat. The static functions below are the
## pieces it can reuse: draw_panel(), draw_row(), draw_gauge(), draw_message() and draw_overlay().

const ViewConfig := preload("res://scripts/view/view_config.gd")
const Atlas := preload("res://scripts/view/atlas.gd")
const Draw := preload("res://scripts/view/draw.gd")
const Config := preload("res://scripts/sim/config.gd")
const World := preload("res://scripts/sim/world.gd")
const Car := preload("res://scripts/sim/car.gd")
const Fuel := preload("res://scripts/sim/fuel.gd")

## The low-fuel warning blinks every this many ticks.
const WARN_BLINK_TICKS := 30

var atlas: Atlas
var font: Font
var cfg: Config
var world: World
## Best score this session, for the game-over panel.
var best: int = 0
## The event message to show, or "".
var message: String = ""


func setup(p_atlas: Atlas, p_cfg: Config) -> void:
	atlas = p_atlas
	font = p_atlas.font
	cfg = p_cfg


func show_world(p_world: World, p_best: int, p_message: String) -> void:
	world = p_world
	best = p_best
	message = p_message
	queue_redraw()


func _draw() -> void:
	if world == null or font == null:
		return
	var car := world.player()
	_draw_left_panel(car)
	_draw_right_panel(car)
	var overlay := overlay_for(world, best)
	if overlay.is_empty():
		draw_message(self, font, cfg, message)
	else:
		draw_overlay(self, font, overlay[0], overlay[1], overlay[2])


func _draw_left_panel(car: Car) -> void:
	var panel := ViewConfig.PANEL_LEFT
	var cx := draw_panel(self, panel)
	var rows := ViewConfig.HUD_ROW_Y
	draw_row(self, font, cx, rows[0], "SCORE", "%06d" % car.score, ViewConfig.WHITE)
	draw_row(self, font, cx, rows[1], "HI", "%06d" % world.high_score, ViewConfig.WHITE)
	draw_row(self, font, cx, rows[2], "STAGE", str(world.stage), ViewConfig.WHITE)
	var progress := clampf(car.y_world / world.goal, 0.0, 1.0) if world.goal > 0.0 else 0.0
	draw_gauge(self, font, cx, "GOAL", ViewConfig.YELLOW, progress, ViewConfig.WHITE)


func _draw_right_panel(car: Car) -> void:
	var panel := ViewConfig.PANEL_RIGHT
	var cx := draw_panel(self, panel)
	var rows := ViewConfig.HUD_ROW_Y
	# Speed: three digits, right-aligned, then "km/h" in small type on the same baseline.
	var small := ViewConfig.TEXT_SMALL
	var medium := ViewConfig.TEXT_MEDIUM
	var speed := "%3d" % floori(car.speed + 0.5)
	var unit := "km/h"
	var speed_w := Draw.text_width(font, speed, medium)
	var width := speed_w + small + Draw.text_width(font, unit, small)
	var x := cx - floori(width / 2.0)
	var value_top: int = rows[0] + ViewConfig.HUD_VALUE_DY
	Draw.text_centred(self, font, cx, rows[0], "SPEED", small, ViewConfig.YELLOW)
	Draw.text(self, font, x, value_top, speed, medium, ViewConfig.WHITE)
	Draw.text(self, font, x + speed_w + small, value_top + medium - small, unit, small, ViewConfig.GREY)
	draw_row(self, font, cx, rows[1], "NITRO", "ON" if car.gear == Car.GEAR_NITRO else "OFF", ViewConfig.YELLOW)
	var low := car.fuel < ViewConfig.LOW_FUEL
	var fuel_colour := ViewConfig.LIGHT_RED if low else ViewConfig.WHITE
	draw_row(self, font, cx, rows[2], "FUEL", "%3d" % floori(car.fuel + 0.5), fuel_colour)
	# Over the gauge, a warning that blinks while the tank is low.
	var warn := "LOW FUEL" if low and floori(world.stage_ticks / float(WARN_BLINK_TICKS)) % 2 == 0 else ""
	var fill := ViewConfig.LIGHT_RED if low else ViewConfig.GRASS
	draw_gauge(self, font, cx, warn, ViewConfig.LIGHT_RED, car.fuel / Config.FUEL_MAX, fill)


## Overlay for the world's phase: [title, lines, panel width], or [] while running.
static func overlay_for(w: World, p_best: int) -> Array:
	var car := w.player()
	match w.phase:
		World.PAUSED:
			return ["PAUSED", ["ESC / P / START to resume"], ViewConfig.PAUSE_PANEL_W]
		World.STAGE_CLEAR:
			return ["STAGE %d CLEAR" % w.stage, [
				"Fuel bonus +%d" % Fuel.stage_clear_bonus(car.fuel),
				"Score %d" % car.score,
				"Next: stage %d, busier road" % (w.stage + 1),
				"",
				"ENTER / A to continue",
			], ViewConfig.RESULT_PANEL_W]
		World.GAME_OVER:
			return ["GAME OVER", [
				"Score %d" % car.score,
				"Best %d" % p_best,
				"",
				"ENTER / A  retry",
				"ESC / START  title",
			], ViewConfig.RESULT_PANEL_W]
	return []


# --- Pieces for any HUD (B2 reuses them for the six seat panels). ---------------------------------------------------


## A dark side panel. Returns its centre x, on which its text is centred.
static func draw_panel(ci: CanvasItem, panel: Rect2i) -> int:
	Draw.rect(ci, panel, Color(ViewConfig.BLACK, ViewConfig.PANEL_ALPHA))
	return panel.position.x + (panel.size.x >> 1)


## A small yellow label with a medium value HUD_VALUE_DY px below it, both centred on cx.
static func draw_row(ci: CanvasItem, font: Font, cx: int, top: int, label: String, value: String, colour: Color) -> void:
	Draw.text_centred(ci, font, cx, top, label, ViewConfig.TEXT_SMALL, ViewConfig.YELLOW)
	Draw.text_centred(ci, font, cx, top + ViewConfig.HUD_VALUE_DY, value, ViewConfig.TEXT_MEDIUM, colour)


## A vertical gauge centred on cx, from GAUGE_TOP to GAUGE_BOTTOM, with a small label above it ("" for none).
static func draw_gauge(ci: CanvasItem, font: Font, cx: int, label: String, label_colour: Color, fraction: float, fill: Color) -> void:
	if not label.is_empty():
		Draw.text_centred(ci, font, cx, ViewConfig.GAUGE_LABEL_Y, label, ViewConfig.TEXT_SMALL, label_colour)
	Draw.gauge(ci, gauge_rect(cx), fraction, fill)


static func gauge_rect(cx: int) -> Rect2i:
	var w := ViewConfig.GAUGE_W
	return Rect2i(cx - (w >> 1), ViewConfig.GAUGE_TOP, w, ViewConfig.GAUGE_BOTTOM - ViewConfig.GAUGE_TOP)


## The lines of an event message: wrapped to the road's width in medium type.
static func message_lines(c: Config, text: String) -> PackedStringArray:
	var road_w := int(c.road_right - c.road_left)
	return Draw.wrap(text, floori(road_w / float(ViewConfig.TEXT_MEDIUM)))


## An event message, centred on the road in shadowed yellow.
static func draw_message(ci: CanvasItem, font: Font, c: Config, text: String) -> void:
	if text.is_empty():
		return
	var size := ViewConfig.TEXT_MEDIUM
	var gap := ViewConfig.MESSAGE_LINE_GAP
	var lines := message_lines(c, text)
	var top := ViewConfig.MESSAGE_CENTRE_Y - floori((lines.size() * (size + gap) - gap) / 2.0)
	var centre := floori((c.road_left + c.road_right) / 2.0)
	for line: String in lines:
		Draw.shadowed_centred(ci, font, centre, top, line, size, ViewConfig.YELLOW)
		top += size + gap


## Size of an overlay panel: width as given, height from its lines (showPanel in Phaser).
static func overlay_rect(lines: int, width: int) -> Rect2i:
	var padding := ViewConfig.OVERLAY_PADDING
	var height := padding * 2 + ViewConfig.OVERLAY_TITLE_GAP + lines * ViewConfig.OVERLAY_LINE_STEP - ViewConfig.OVERLAY_LINE_GAP
	var left := floori((ViewConfig.VIEW_W - width) / 2.0 + 0.5)
	var top := floori((ViewConfig.VIEW_H - height) / 2.0 + 0.5)
	return Rect2i(left, top, width, height)


## Dims the screen and shows a centred panel sized to its text: a medium title over small lines.
static func draw_overlay(ci: CanvasItem, font: Font, title: String, lines: Array, width: int) -> void:
	var r := overlay_rect(lines.size(), width)
	Draw.rect(ci, Rect2i(0, 0, ViewConfig.VIEW_W, ViewConfig.VIEW_H), Color(0, 0, 0, ViewConfig.OVERLAY_DIM))
	Draw.box(ci, r)
	var centre := r.position.x + (r.size.x >> 1)
	var top := r.position.y + ViewConfig.OVERLAY_PADDING
	Draw.shadowed_centred(ci, font, centre, top, title, ViewConfig.TEXT_MEDIUM, ViewConfig.YELLOW)
	var y := top + ViewConfig.OVERLAY_TITLE_GAP
	for line: String in lines:
		if not line.is_empty():
			Draw.text_centred(ci, font, centre, y, line, ViewConfig.TEXT_SMALL, ViewConfig.WHITE)
		y += ViewConfig.OVERLAY_LINE_STEP
