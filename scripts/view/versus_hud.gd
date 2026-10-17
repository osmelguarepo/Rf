extends Node2D
## The versus HUD (B2; first version, B2b gives it its final layout and look): a panel per seat in the two side
## columns, and the pause, round-over and match-over panels over the road.
##
## Seat panels: seats 0 to 2 down the left column, 3 to 5 down the right (seat_panel_rect()), so a seat's panel is in
## the same place in every match; seats without a car draw nothing. Each shows (seat_info()): a swatch of the seat's
## colour and its name (P1 to P6, or BOT), the round wins, the points this round, a fuel gauge, and the marks OUT (out
## of the round), EDGE (touching the bottom edge), LOW FUEL (blinking) and NO PAD (a person's seat whose pad has gone:
## its bot drives).
##
## Panels over the road (overlay_for()): PAUSED; after a round, every seat's points, distance, OUT and wins, the round's
## winner or NO WINNER, and PRESS A once the match takes the confirm (Config.MATCH_CONFIRM_TICKS); after the match, its
## winner in its colour, or DRAW (several people) or YOU LOSE (one person against bots), every seat's wins and total
## points, and the rematch and join-screen keys once they count.
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

## Three seat panels down each column, inside ViewConfig.PANEL_LEFT and PANEL_RIGHT.
const SEAT_PANEL_H := 108
const SEAT_PANEL_GAP := 10
const SEATS_PER_COLUMN := 3
const INSET := 8
const SWATCH := 12
const NAME_DY := 6
const SCORE_DY := 28
const GAUGE_DY := 50
const GAUGE_H := 10
const MARK_DY := 68
const PAD_MARK_DY := 84
## Marks blink every this many ticks (the low-fuel warning, as in single player).
const BLINK_TICKS := Hud.WARN_BLINK_TICKS
## The round-over and match-over panels' width.
const RESULTS_W := 336

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


## What a slot's panel shows: {seat, name, score, fuel, wins, out, edge, low_fuel, no_pad}.
static func seat_info(m: Match, p_lineup: Array[int], p_pads: Array[bool], slot: int) -> Dictionary:
	var car: Car = m.world.players[slot]
	var person := car.human != 0
	return {
		"seat": p_lineup[slot],
		"name": PlayerColours.label(p_lineup[slot], person),
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


## The panel over the road for the match's state: {title, lines: [[text, colour], ...], width}, or {} while racing.
static func overlay_for(m: Match, p_lineup: Array[int]) -> Dictionary:
	if m.phase == Match.MATCH_OVER:
		return {"title": "MATCH OVER", "lines": match_lines(m, p_lineup), "width": RESULTS_W}
	if m.phase == Match.ROUND_OVER:
		return {"title": "ROUND %d OVER" % m.round_number, "lines": round_lines(m, p_lineup), "width": RESULTS_W}
	if m.world.phase == World.PAUSED:
		return {"title": "PAUSED", "lines": [
			["START  resume", ViewConfig.WHITE],
			["BACK / ESC  quit to title", ViewConfig.WHITE],
		], "width": ViewConfig.PAUSE_PANEL_W}
	return {}


## A results row; every row of a table has the same length, so the columns line up when centred (the font is
## monospaced).
static func row(name: String, a: String, b: String, c: String, d: String) -> String:
	return "%-3s  %6s  %6s  %-3s  %2s" % [name, a, b, c, d]


## Round over: a row per seat (points, distance, OUT, wins), the winner, and PRESS A once it counts.
static func round_lines(m: Match, p_lineup: Array[int]) -> Array:
	var lines: Array = [[row("", "POINTS", "DIST", "", "W"), ViewConfig.GREY]]
	for slot in p_lineup.size():
		var car: Car = m.world.players[slot]
		var seat := p_lineup[slot]
		var text := row(PlayerColours.label(seat, car.human != 0), "%06d" % car.score, "%06d" % floori(car.distance),
			"OUT" if car.alive == 0 else "", str(m.wins[slot]))
		lines.append([text, PlayerColours.text_colour(seat)])
	lines.append(["", ViewConfig.WHITE])
	var winner := m.last_round_winner()
	if winner == Match.NO_WINNER:
		lines.append(["NO WINNER", ViewConfig.WHITE])
	else:
		lines.append(["%s WINS THE ROUND" % PlayerColours.label(p_lineup[winner], true), PlayerColours.text_colour(p_lineup[winner])])
	lines.append(["", ViewConfig.WHITE])
	lines.append(["PRESS A" if m.phase_ticks >= Config.MATCH_CONFIRM_TICKS else "", ViewConfig.YELLOW])
	return lines


## Match over: the winner (or DRAW, or YOU LOSE), a row per seat (wins, total points), and the keys once they count.
static func match_lines(m: Match, p_lineup: Array[int]) -> Array:
	var lines: Array = []
	if m.winner != Match.NO_WINNER:
		var seat := p_lineup[m.winner]
		lines.append(["%s WINS THE MATCH" % PlayerColours.label(seat, true), PlayerColours.text_colour(seat)])
	elif m.human_seats().size() > 1:
		lines.append(["DRAW", ViewConfig.WHITE])
	else:
		lines.append(["YOU LOSE", ViewConfig.LIGHT_RED])
	lines.append(["", ViewConfig.WHITE])
	lines.append([row("", "TOTAL", "", "", "W"), ViewConfig.GREY])
	for slot in p_lineup.size():
		var car: Car = m.world.players[slot]
		var seat := p_lineup[slot]
		var text := row(PlayerColours.label(seat, car.human != 0), "%06d" % m.totals[slot], "", "", str(m.wins[slot]))
		lines.append([text, PlayerColours.text_colour(seat)])
	lines.append(["", ViewConfig.WHITE])
	var ready := m.phase_ticks >= Config.MATCH_CONFIRM_TICKS
	lines.append(["A  REMATCH    B  JOIN SCREEN" if ready else "", ViewConfig.YELLOW])
	return lines


func _draw() -> void:
	if game_match == null or font == null:
		return
	for slot in lineup.size():
		draw_seat_panel(seat_info(game_match, lineup, pads, slot))
	var overlay := overlay_for(game_match, lineup)
	if not overlay.is_empty():
		draw_panel(overlay["title"], overlay["lines"], overlay["width"])


## One seat's panel.
func draw_seat_panel(info: Dictionary) -> void:
	var seat: int = info["seat"]
	var r := seat_panel_rect(seat)
	var cx := Hud.draw_panel(self, r)
	var x := r.position.x
	var y := r.position.y
	Draw.rect(self, Rect2i(x + INSET, y + NAME_DY + 2, SWATCH, SWATCH), PlayerColours.colour(seat))
	Draw.text(self, font, x + INSET + SWATCH + 6, y + NAME_DY, info["name"], ViewConfig.TEXT_MEDIUM, PlayerColours.text_colour(seat))
	var wins := "W%d" % info["wins"]
	var wins_x := r.end.x - INSET - Draw.text_width(font, wins, ViewConfig.TEXT_SMALL)
	Draw.text(self, font, wins_x, y + NAME_DY + 4, wins, ViewConfig.TEXT_SMALL, ViewConfig.YELLOW)
	Draw.text_centred(self, font, cx, y + SCORE_DY, "%06d" % info["score"], ViewConfig.TEXT_MEDIUM, ViewConfig.WHITE)
	var low: bool = info["low_fuel"]
	var fuel: float = info["fuel"]
	draw_bar(Rect2i(x + INSET, y + GAUGE_DY, r.size.x - 2 * INSET, GAUGE_H), fuel / Config.FUEL_MAX,
		ViewConfig.LIGHT_RED if low else ViewConfig.GRASS)
	var mark := mark_of(info)
	var blink_off := mark == "LOW FUEL" and floori(game_match.world.stage_ticks / float(BLINK_TICKS)) % 2 == 1
	if not mark.is_empty() and not blink_off:
		var colour := ViewConfig.YELLOW if mark == "EDGE" else ViewConfig.LIGHT_RED
		Draw.text_centred(self, font, cx, y + MARK_DY, mark, ViewConfig.TEXT_SMALL, colour)
	if info["no_pad"]:
		Draw.text_centred(self, font, cx, y + PAD_MARK_DY, "NO PAD", ViewConfig.TEXT_SMALL, ViewConfig.WHITE)


## A horizontal gauge filled from the left: a white rim, a black gap, then the bar (as Draw.gauge(), on its side).
func draw_bar(r: Rect2i, fraction: float, fill: Color) -> void:
	var rim := 2
	var inset := rim * 2
	Draw.rect(self, r, ViewConfig.WHITE)
	Draw.rect(self, r.grow(-rim), ViewConfig.BLACK)
	var full := r.size.x - inset * 2
	var width := roundi(full * clampf(fraction, 0.0, 1.0))
	Draw.rect(self, Rect2i(r.position.x + inset, r.position.y + inset, width, r.size.y - inset * 2), fill)


## Dims the screen and shows a panel: a medium title over small lines, each in its own colour.
func draw_panel(title: String, lines: Array, width: int) -> void:
	var r := Hud.overlay_rect(lines.size(), width)
	Draw.rect(self, Rect2i(0, 0, ViewConfig.VIEW_W, ViewConfig.VIEW_H), Color(0, 0, 0, ViewConfig.OVERLAY_DIM))
	Draw.box(self, r)
	var centre := r.position.x + (r.size.x >> 1)
	var top := r.position.y + ViewConfig.OVERLAY_PADDING
	Draw.shadowed_centred(self, font, centre, top, title, ViewConfig.TEXT_MEDIUM, ViewConfig.YELLOW)
	var y := top + ViewConfig.OVERLAY_TITLE_GAP
	for line: Array in lines:
		var text: String = line[0]
		if not text.is_empty():
			Draw.text_centred(self, font, centre, y, text, ViewConfig.TEXT_SMALL, line[1])
		y += ViewConfig.OVERLAY_LINE_STEP
