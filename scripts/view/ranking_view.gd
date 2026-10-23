extends Node2D
## The leaderboard's drawing: a panel over the road with a row per player, best first: place, name, division and
## ranking points. A session with no match yet says so.

const ViewConfig := preload("res://scripts/view/view_config.gd")
const Atlas := preload("res://scripts/view/atlas.gd")
const Draw := preload("res://scripts/view/draw.gd")
const Hud := preload("res://scripts/view/hud.gd")
const Ranking := preload("res://scripts/sim/ranking.gd")

## Rows the panel shows.
const ROWS := 8
const WIDTH := 336
## Columns, from the panel's table left edge: the place, the name, the division, the points (right-aligned in 64).
const COLUMN_X := [0, 40, 112, 216]
const COLUMN_W := 64
const TABLE_W := 280

var atlas: Atlas
var font: Font
var records: Array[Dictionary] = []


func setup(p_atlas: Atlas, p_records: Array[Dictionary]) -> void:
	atlas = p_atlas
	font = p_atlas.font
	records = p_records
	queue_redraw()


## The texts of the rows, for the panel and for tests: "1 P2 GOLD 730".
static func row_texts(p_records: Array[Dictionary]) -> Array[String]:
	var rows: Array[String] = []
	for i in p_records.size():
		var r := p_records[i]
		rows.append("%d %s %s %d" % [i + 1, r["name"], Ranking.division_name(r["points"]), r["points"]])
	return rows


## The panel's rect: sized to its rows (at least one line, for the empty message).
static func panel_rect(p_records: Array[Dictionary]) -> Rect2i:
	return Hud.overlay_rect(maxi(1, p_records.size()) + 2, WIDTH)


func _draw() -> void:
	if font == null:
		return
	var r := panel_rect(records)
	Draw.box(self, r)
	var centre := r.position.x + (r.size.x >> 1)
	var top := r.position.y + ViewConfig.OVERLAY_PADDING
	Draw.shadowed_centred(self, font, centre, top, "RANKING", ViewConfig.TEXT_MEDIUM, ViewConfig.YELLOW)
	var y := top + ViewConfig.OVERLAY_TITLE_GAP
	var small := ViewConfig.TEXT_SMALL
	if records.is_empty():
		Draw.text_centred(self, font, centre, y, "NO MATCH PLAYED YET", small, ViewConfig.GREY)
	var left := r.position.x + ((r.size.x - TABLE_W) >> 1)
	for i in records.size():
		var rec := records[i]
		Draw.text(self, font, left + COLUMN_X[0], y, str(i + 1), small, ViewConfig.GREY)
		Draw.text(self, font, left + COLUMN_X[1], y, rec["name"], small, ViewConfig.WHITE)
		Draw.text(self, font, left + COLUMN_X[2], y, Ranking.division_name(rec["points"]), small, ViewConfig.YELLOW)
		var points := str(rec["points"])
		Draw.text(self, font, left + COLUMN_X[3] + COLUMN_W - Draw.text_width(font, points, small), y, points, small, ViewConfig.WHITE)
		y += ViewConfig.OVERLAY_LINE_STEP
	y += ViewConfig.OVERLAY_LINE_STEP
	Draw.text_centred(self, font, centre, y, "ANY KEY  BACK", small, ViewConfig.GREY)
