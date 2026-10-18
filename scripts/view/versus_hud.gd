extends Node2D
## The versus HUD (B2): a panel per seat in the two side columns, and the pause, round-over and match-over panels over
## the road.
##
## Seat panels: seats 0 to 2 down the left column, 3 to 5 down the right (seat_panel_rect()), so a seat's panel is in
## the same place in every match; seats without a car draw nothing. The panels stay on the grass beside the road
## (ViewConfig.PANEL_LEFT and PANEL_RIGHT), so they never hide a car. Each shows (seat_info()), in a border of the
## seat's colour: the seat's car as it looks on the road, its name (P1 to P6, or BOT), a pip per round it won (people
## only: bots cannot win), the points this round, a fuel gauge (red when low), and two lines of marks (marks_of()):
## first OUT (out of the round: the panel dims), EDGE (touching the bottom edge, which drains the tank) or LOW FUEL
## (blinking); then, for a person's seat whose pad has gone (its bot drives), NO PAD and PRESS A in turn (any pad that
## holds no seat takes the seat with A), or else LOW FUEL under EDGE.
##
## Panels over the road (overlay_for()), which dim the screen: PAUSED; after a round, a row per seat (its badge, the
## round's points and distance, OUT, its wins), the round's winner or NO WINNER, and PRESS A once the match takes the
## confirm (Config.MATCH_CONFIRM_TICKS); after the match, its winner, or DRAW (several people) or YOU LOSE (one person
## against bots), a row per seat (points and distance over the match, wins), and the rematch and join-screen keys once
## they count. A seat is named by a badge: its name on its colour (PlayerColours.ink() for the text), so a dark or
## light car colour never makes small text hard to read.
##
## Text sizes are ViewConfig.TEXT_SIZES; colours of seats come from player_colours.gd.

const ViewConfig := preload("res://scripts/view/view_config.gd")
const Atlas := preload("res://scripts/view/atlas.gd")
const Draw := preload("res://scripts/view/draw.gd")
const Hud := preload("res://scripts/view/hud.gd")
const PlayerColours := preload("res://scripts/view/player_colours.gd")
const Config := preload("res://scripts/sim/config.gd")
const World := preload("res://scripts/sim/world.gd")
const Match := preload("res://scripts/sim/match.gd")
const Car := preload("res://scripts/sim/car.gd")

# --- Seat panels: three down each column, inside ViewConfig.PANEL_LEFT and PANEL_RIGHT. Offsets from a panel's
# top-left corner.
const SEAT_PANEL_H := 108
const SEAT_PANEL_GAP := 10
const SEATS_PER_COLUMN := 3
const BORDER := 2
const INSET := 8
## The seat's car, upright, at ViewConfig.SPRITE_SCALE.
const CAR_DX := 8
const CAR_DY := 7
## The name, in medium type, right of the car.
const NAME_DX := 32
const NAME_DY := 12
## Win pips, right-aligned: one per win the match needs.
const PIP := 8
const PIP_GAP := 4
const PIP_DY := 16
const SCORE_DY := 40
const GAUGE_DY := 60
const GAUGE_H := 14
## The two lines of marks (marks_of()).
const MARK_DY := 80
const PAD_MARK_DY := 92
## How much of a panel shows once its car is out.
const OUT_ALPHA := 0.4
## The low-fuel mark blinks every this many ticks (the single-player warning's rate).
const BLINK_TICKS := Hud.WARN_BLINK_TICKS
## A seat whose pad has gone shows NO PAD and PRESS A in turn, each for this many world ticks (World.tick, which counts
## in every phase: paused and between rounds too).
const PAD_BLINK_TICKS := 60

# --- Panels over the road.
## The round-over and match-over panels: as wide as the road and its verges, clear of the seat panels.
const RESULTS_W := 336
## A seat's badge in a table: its name in small type on its colour.
const BADGE_W := 32
const BADGE_H := 12
## Table columns: x from the table's left edge, and each cell's width (cells are right-aligned in it, but for the
## wins column's heading, centred over its pips).
const COLUMN_X := [48, 112, 176, 216]
const COLUMN_W := [48, 48, 24, 20]
## The wins column: rows draw their win pips in it (Config.MATCH_WINS of them, as wide as the column).
const WINS_COLUMN := 3
## Kinds of line in a panel over the road (lines of overlay_for()).
const TEXT := 0
const HEAD := 1
const ROW := 2
const WINNER := 3

var atlas: Atlas
var font: Font
var cfg: Config
var game_match: Match
## World slot -> seat.
var lineup: Array[int] = []
## Per slot: false for a person's seat whose pad has gone.
var pads: Array[bool] = []


func setup(p_atlas: Atlas, p_cfg: Config) -> void:
	atlas = p_atlas
	font = p_atlas.font
	cfg = p_cfg


func show_match(m: Match, p_lineup: Array[int], p_pads: Array[bool]) -> void:
	game_match = m
	lineup = p_lineup
	pads = p_pads
	queue_redraw()


## A seat's panel: seats 0 to 2 down the left column, 3 to 5 down the right.
static func seat_panel_rect(seat: int) -> Rect2i:
	var column := ViewConfig.PANEL_LEFT if seat < SEATS_PER_COLUMN else ViewConfig.PANEL_RIGHT
	var row := seat % SEATS_PER_COLUMN
	return Rect2i(column.position.x, column.position.y + row * (SEAT_PANEL_H + SEAT_PANEL_GAP), column.size.x, SEAT_PANEL_H)


## What a slot's panel shows: {seat, name, person, score, fuel, wins, out, edge, low_fuel, no_pad}.
static func seat_info(m: Match, p_lineup: Array[int], p_pads: Array[bool], slot: int) -> Dictionary:
	var car: Car = m.world.players[slot]
	var person := car.human != 0
	return {
		"seat": p_lineup[slot],
		"name": PlayerColours.label(p_lineup[slot], person),
		"person": person,
		"score": car.score,
		"fuel": car.fuel,
		"wins": m.wins[slot],
		"out": car.alive == 0,
		"edge": car.alive != 0 and car.touching_edge != 0,
		"low_fuel": car.alive != 0 and car.fuel < ViewConfig.LOW_FUEL,
		"no_pad": person and slot < p_pads.size() and not p_pads[slot],
	}


## The first mark of a panel, by priority: OUT, EDGE, LOW FUEL; "" for none.
static func mark_of(info: Dictionary) -> String:
	if info["out"]:
		return "OUT"
	if info["edge"]:
		return "EDGE"
	if info["low_fuel"]:
		return "LOW FUEL"
	return ""


## A panel's two lines of marks, "" for none: the first is mark_of(); the second NO PAD for a person's seat whose pad
## has gone, or else LOW FUEL while the first shows EDGE (a car on the bottom edge loses fuel fastest, so its low tank
## must show too). draw_seat_panel() blinks LOW FUEL, and shows NO PAD as pad_mark().
static func marks_of(info: Dictionary) -> Array[String]:
	var first := mark_of(info)
	var second := ""
	if info["no_pad"]:
		second = "NO PAD"
	elif first == "EDGE" and info["low_fuel"]:
		second = "LOW FUEL"
	return [first, second]


## What a seat whose pad has gone says at a world tick: NO PAD, then PRESS A (how another pad takes the seat), each for
## PAD_BLINK_TICKS.
static func pad_mark(tick: int) -> String:
	return "NO PAD" if floori(tick / float(PAD_BLINK_TICKS)) % 2 == 0 else "PRESS A"


## The panel over the road for the match's state, or {} while a round runs: {title, width, lines}. Each line is a
## Dictionary with a "kind": TEXT {text, colour}; HEAD {cells} (column headings); ROW {seat, name, cells, wins, person}
## (a seat's badge, then its cells in the columns, then its win pips); WINNER {seat, name, text} (a badge, then the
## text).
static func overlay_for(m: Match, p_lineup: Array[int]) -> Dictionary:
	if m.phase == Match.MATCH_OVER:
		return {"title": "MATCH OVER", "lines": match_lines(m, p_lineup), "width": RESULTS_W}
	if m.phase == Match.ROUND_OVER:
		return {"title": "ROUND %d OVER" % m.round_number, "lines": round_lines(m, p_lineup), "width": RESULTS_W}
	if m.world.phase == World.PAUSED:
		return {"title": "PAUSED", "lines": [
			text_line("START  resume"),
			text_line("BACK / ESC  quit to title"),
		], "width": ViewConfig.PAUSE_PANEL_W}
	return {}


static func text_line(text: String, colour: Color = ViewConfig.WHITE) -> Dictionary:
	return {"kind": TEXT, "text": text, "colour": colour}


## A table row of a slot: its seat's badge, the cells, its wins.
static func seat_row(m: Match, p_lineup: Array[int], slot: int, cells: Array) -> Dictionary:
	var person: bool = m.world.players[slot].human != 0
	var seat := p_lineup[slot]
	return {"kind": ROW, "seat": seat, "name": PlayerColours.label(seat, person), "cells": cells, "wins": m.wins[slot], "person": person}


## A line naming a winner: the seat's badge and the text after it.
static func winner_line(seat: int, text: String) -> Dictionary:
	return {"kind": WINNER, "seat": seat, "name": PlayerColours.label(seat, true), "text": text}


## Round over: a row per seat (points, distance, OUT, wins), the winner, and PRESS A once it counts.
static func round_lines(m: Match, p_lineup: Array[int]) -> Array:
	var lines: Array = [{"kind": HEAD, "cells": ["POINTS", "DIST", "", "WINS"]}]
	for slot in p_lineup.size():
		var car: Car = m.world.players[slot]
		lines.append(seat_row(m, p_lineup, slot, ["%06d" % car.score, "%06d" % floori(car.distance), "OUT" if car.alive == 0 else ""]))
	lines.append(text_line(""))
	var winner := m.last_round_winner()
	if winner == Match.NO_WINNER:
		lines.append(text_line("NO WINNER"))
	else:
		lines.append(winner_line(p_lineup[winner], "WINS THE ROUND"))
	lines.append(text_line(""))
	lines.append(text_line("PRESS A" if m.phase_ticks >= Config.MATCH_CONFIRM_TICKS else "", ViewConfig.YELLOW))
	return lines


## Match over: the winner (or DRAW, or YOU LOSE), a row per seat (points and distance over the match, wins), and the
## keys once they count.
static func match_lines(m: Match, p_lineup: Array[int]) -> Array:
	var lines: Array = []
	if m.winner != Match.NO_WINNER:
		lines.append(winner_line(p_lineup[m.winner], "WINS THE MATCH"))
	elif m.human_seats().size() > 1:
		lines.append(text_line("DRAW"))
	else:
		lines.append(text_line("YOU LOSE", ViewConfig.LIGHT_RED))
	lines.append(text_line(""))
	lines.append({"kind": HEAD, "cells": ["TOTAL", "DIST", "", "WINS"]})
	for slot in p_lineup.size():
		lines.append(seat_row(m, p_lineup, slot, ["%06d" % m.totals[slot], "%06d" % floori(m.distances[slot]), ""]))
	lines.append(text_line(""))
	var ready := m.phase_ticks >= Config.MATCH_CONFIRM_TICKS
	lines.append(text_line("A  REMATCH    B  JOIN SCREEN" if ready else "", ViewConfig.YELLOW))
	return lines


## What a line says, as one string: the badge's name and the cells or text after it (for measuring and tests).
static func line_text(line: Dictionary) -> String:
	match int(line["kind"]):
		HEAD:
			return " ".join(line["cells"]).strip_edges()
		ROW:
			return ("%s %s" % [line["name"], " ".join(line["cells"])]).strip_edges()
		WINNER:
			return "%s %s" % [line["name"], line["text"]]
	return line["text"]


## The texts of a panel's lines.
static func texts(overlay: Dictionary) -> Array:
	var out: Array = []
	for line: Dictionary in overlay["lines"]:
		out.append(line_text(line))
	return out


## Where a panel over the road goes: centred, sized to its lines (Hud.overlay_rect()).
static func panel_rect(overlay: Dictionary) -> Rect2i:
	return Hud.overlay_rect((overlay["lines"] as Array).size(), overlay["width"])


## The x where a table row starts, inside a results panel of this rect: the table (badge, then the columns) is
## centred.
static func table_left(r: Rect2i) -> int:
	var table_w: int = COLUMN_X.back() + COLUMN_W.back()
	return r.position.x + ((r.size.x - table_w) >> 1)


func _draw() -> void:
	if game_match == null or font == null:
		return
	for slot in lineup.size():
		draw_seat_panel(seat_info(game_match, lineup, pads, slot))
	var overlay := overlay_for(game_match, lineup)
	if not overlay.is_empty():
		draw_overlay(overlay)


# --- Seat panels -------------------------------------------------------------------------------------------------------


## One seat's panel.
func draw_seat_panel(info: Dictionary) -> void:
	var seat: int = info["seat"]
	var r := seat_panel_rect(seat)
	var out: bool = info["out"]
	var fade := OUT_ALPHA if out else 1.0
	Hud.draw_panel(self, r)
	_frame(r, Color(ViewConfig.GREY if out else PlayerColours.colour(seat), fade))
	var x := r.position.x
	var y := r.position.y
	var spec := PlayerColours.seat_sprite(ViewConfig.PLAYER, seat)
	var tex := atlas.frame(spec["frame"]) if atlas != null else null
	if tex != null:
		var size := Vector2i(tex.get_width(), tex.get_height()) * ViewConfig.SPRITE_SCALE
		draw_texture_rect(tex, Rect2(Vector2i(x + CAR_DX, y + CAR_DY), size), false, Color(1, 1, 1, fade))
	else:
		Draw.rect(self, Rect2i(x + CAR_DX, y + CAR_DY, 16, 24), Color(PlayerColours.colour(seat), fade))
	Draw.text(self, font, x + NAME_DX, y + NAME_DY, info["name"], ViewConfig.TEXT_MEDIUM, Color(ViewConfig.WHITE, fade))
	if info["person"]:
		_draw_pips(Vector2i(r.end.x - INSET, y + PIP_DY), info["wins"], fade)
	var cx := x + (r.size.x >> 1)
	var score := "%06d" % info["score"]
	Draw.text_centred(self, font, cx, y + SCORE_DY, score, ViewConfig.TEXT_MEDIUM, Color(ViewConfig.WHITE, fade))
	var low: bool = info["low_fuel"]
	var fuel: float = 0.0 if out else info["fuel"]
	draw_bar(Rect2i(x + INSET, y + GAUGE_DY, r.size.x - 2 * INSET, GAUGE_H), fuel / Config.FUEL_MAX,
		ViewConfig.LIGHT_RED if low else ViewConfig.GRASS, fade)
	var low_off := floori(game_match.world.stage_ticks / float(BLINK_TICKS)) % 2 == 1
	var marks := marks_of(info)
	for line in marks.size():
		var mark: String = marks[line]
		if mark.is_empty() or (mark == "LOW FUEL" and low_off):
			continue
		var colour := ViewConfig.LIGHT_RED
		if mark == "EDGE":
			colour = ViewConfig.YELLOW
		elif mark == "NO PAD":
			mark = pad_mark(game_match.world.tick)
			colour = ViewConfig.WHITE if mark == "NO PAD" else ViewConfig.YELLOW
		Draw.text_centred(self, font, cx, y + (MARK_DY if line == 0 else PAD_MARK_DY), mark, ViewConfig.TEXT_SMALL, colour)


## A border of BORDER px just inside a rect.
func _frame(r: Rect2i, colour: Color) -> void:
	Draw.rect(self, Rect2i(r.position.x, r.position.y, r.size.x, BORDER), colour)
	Draw.rect(self, Rect2i(r.position.x, r.end.y - BORDER, r.size.x, BORDER), colour)
	Draw.rect(self, Rect2i(r.position.x, r.position.y + BORDER, BORDER, r.size.y - 2 * BORDER), colour)
	Draw.rect(self, Rect2i(r.end.x - BORDER, r.position.y + BORDER, BORDER, r.size.y - 2 * BORDER), colour)


## Config.MATCH_WINS pips in a row whose top-right corner is `at`: yellow for each round won, an empty box for the
## others.
func _draw_pips(at: Vector2i, wins: int, fade: float = 1.0) -> void:
	var count := Config.MATCH_WINS
	var left := at.x - count * PIP - (count - 1) * PIP_GAP
	for i in count:
		var pip := Rect2i(left + i * (PIP + PIP_GAP), at.y, PIP, PIP)
		if i < wins:
			Draw.rect(self, pip, Color(ViewConfig.YELLOW, fade))
		else:
			Draw.rect(self, pip, Color(ViewConfig.GREY, fade))
			Draw.rect(self, pip.grow(-1), Color(ViewConfig.BLACK, fade))


## A horizontal gauge filled from the left: a white rim, a black gap, then the bar (as Draw.gauge(), on its side).
func draw_bar(r: Rect2i, fraction: float, fill: Color, fade: float = 1.0) -> void:
	var rim := 2
	var inset := rim * 2
	Draw.rect(self, r, Color(ViewConfig.WHITE, fade))
	Draw.rect(self, r.grow(-rim), ViewConfig.BLACK)
	var full := r.size.x - inset * 2
	var width := roundi(full * clampf(fraction, 0.0, 1.0))
	Draw.rect(self, Rect2i(r.position.x + inset, r.position.y + inset, width, r.size.y - inset * 2), Color(fill, fade))


# --- Panels over the road ----------------------------------------------------------------------------------------------


## Dims the screen and shows a panel: a medium title over small lines (plain text, table headings and rows with
## badges, a winner's badge and text).
func draw_overlay(overlay: Dictionary) -> void:
	var r := panel_rect(overlay)
	Draw.rect(self, Rect2i(0, 0, ViewConfig.VIEW_W, ViewConfig.VIEW_H), Color(0, 0, 0, ViewConfig.OVERLAY_DIM))
	Draw.box(self, r)
	var centre := r.position.x + (r.size.x >> 1)
	var top := r.position.y + ViewConfig.OVERLAY_PADDING
	Draw.shadowed_centred(self, font, centre, top, overlay["title"], ViewConfig.TEXT_MEDIUM, ViewConfig.YELLOW)
	var y := top + ViewConfig.OVERLAY_TITLE_GAP
	var left := table_left(r)
	for line: Dictionary in overlay["lines"]:
		match int(line["kind"]):
			TEXT:
				if not (line["text"] as String).is_empty():
					Draw.text_centred(self, font, centre, y, line["text"], ViewConfig.TEXT_SMALL, line["colour"])
			HEAD:
				_draw_cells(left, y, line["cells"], ViewConfig.GREY)
			ROW:
				draw_badge(Vector2i(left, y - ((BADGE_H - ViewConfig.TEXT_SMALL) >> 1)), line["seat"], line["name"])
				_draw_cells(left, y, line["cells"], ViewConfig.WHITE)
				if line["person"]:
					_draw_pips(Vector2i(left + COLUMN_X[WINS_COLUMN] + COLUMN_W[WINS_COLUMN], y), line["wins"])
			WINNER:
				var text := " " + str(line["text"])
				var width := BADGE_W + Draw.text_width(font, text, ViewConfig.TEXT_SMALL)
				var x := centre - (width >> 1)
				draw_badge(Vector2i(x, y - ((BADGE_H - ViewConfig.TEXT_SMALL) >> 1)), line["seat"], line["name"])
				Draw.text(self, font, x + BADGE_W, y, text, ViewConfig.TEXT_SMALL, ViewConfig.WHITE)
		y += ViewConfig.OVERLAY_LINE_STEP


## A seat's badge: its name centred in small type on its colour, in the ink that stands out there.
func draw_badge(at: Vector2i, seat: int, name: String) -> void:
	Draw.rect(self, Rect2i(at, Vector2i(BADGE_W, BADGE_H)), PlayerColours.colour(seat))
	var ink := PlayerColours.ink(seat)
	var top := at.y + ((BADGE_H - ViewConfig.TEXT_SMALL) >> 1)
	Draw.text_centred(self, font, at.x + (BADGE_W >> 1), top, name, ViewConfig.TEXT_SMALL, ink)


## Cells of a table line, each where cell_x() puts it (the wins column only has a heading).
func _draw_cells(left: int, top: int, cells: Array, colour: Color) -> void:
	for i in cells.size():
		var text: String = cells[i]
		if text.is_empty():
			continue
		var ink := ViewConfig.LIGHT_RED if text == "OUT" else colour
		var x := cell_x(left, i, Draw.text_width(font, text, ViewConfig.TEXT_SMALL))
		Draw.text(self, font, x, top, text, ViewConfig.TEXT_SMALL, ink)


## The left x of a table cell `width` px wide in a column, for a table whose left edge is `left`: right-aligned in the
## column; the wins column's heading centred over its pips, so it may stick out of the column on both sides.
static func cell_x(left: int, column: int, width: int) -> int:
	if column == WINS_COLUMN:
		return left + COLUMN_X[column] + ((COLUMN_W[column] - width) >> 1)
	return left + COLUMN_X[column] + COLUMN_W[column] - width
