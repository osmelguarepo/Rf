extends Node2D
## The drawing of the login and queue screens (docs/SPEC_ONLINE.md §16.4, §16.5): over the dimmed road, the title, a subtitle, then
## an optional menu of rows, a headline, a few lines, a message and the key hints. The screens (login_screen.gd, queue_screen.gd)
## decide everything and hand this a Dictionary:
##   {"title", "subtitle", "rows": [String], "focus", "headline", "lines": [String], "message", "good": bool, "hints": [String]}
## Text sizes are the game's four (ViewConfig.TEXT_*): 8, 16, 24 and 32.

const ViewConfig := preload("res://scripts/view/view_config.gd")
const Atlas := preload("res://scripts/view/atlas.gd")
const Draw := preload("res://scripts/view/draw.gd")

const TITLE_TOP := 14
const SUBTITLE_TOP := 54
const ROWS_TOP := 84
const ROW_STEP := 32
const ROW_W := 360
const ROW_H := 26
const HEADLINE_TOP := 100
const LINES_TOP := 144
const LINES_STEP := 16
const MESSAGE_TOP := 262
const HINTS_TOP := 304
const HINTS_STEP := 12

var atlas: Atlas
var font: Font
var data: Dictionary = {}


func setup(p_atlas: Atlas) -> void:
	atlas = p_atlas
	font = p_atlas.font
	queue_redraw()


func show_state(p_data: Dictionary) -> void:
	data = p_data
	queue_redraw()


## The rectangle of a menu row, for the tests and for a click.
static func row_rect(row: int) -> Rect2i:
	return Rect2i((ViewConfig.VIEW_W - ROW_W) >> 1, ROWS_TOP + row * ROW_STEP, ROW_W, ROW_H)


func _draw() -> void:
	if font == null or data.is_empty():
		return
	var centre := ViewConfig.VIEW_W >> 1
	Draw.rect(self, Rect2i(0, 0, ViewConfig.VIEW_W, ViewConfig.VIEW_H), Color(0, 0, 0, ViewConfig.OVERLAY_DIM))
	Draw.shadowed_centred(self, font, centre, TITLE_TOP, String(data.get("title", "ONLINE")), ViewConfig.TEXT_HUGE, ViewConfig.YELLOW)
	Draw.text_centred(self, font, centre, SUBTITLE_TOP, String(data.get("subtitle", "")), ViewConfig.TEXT_SMALL, ViewConfig.WHITE)
	var rows: Array = data.get("rows", [])
	for i in rows.size():
		var focused: bool = i == int(data.get("focus", -1))
		var r := row_rect(i)
		Draw.box(self, r, ViewConfig.YELLOW if focused else ViewConfig.GREY, 0.0)
		Draw.text_centred(self, font, centre, r.position.y + 9, String(rows[i]), ViewConfig.TEXT_SMALL, ViewConfig.YELLOW if focused else ViewConfig.WHITE)
	var headline := String(data.get("headline", ""))
	if not headline.is_empty():
		Draw.shadowed_centred(self, font, centre, HEADLINE_TOP, headline, ViewConfig.TEXT_MEDIUM, ViewConfig.WHITE)
	var top := LINES_TOP if rows.is_empty() else ROWS_TOP + rows.size() * ROW_STEP + 8
	for line: String in data.get("lines", []):
		Draw.text_centred(self, font, centre, top, line, ViewConfig.TEXT_SMALL, ViewConfig.WHITE)
		top += LINES_STEP
	var message := String(data.get("message", ""))
	if not message.is_empty():
		Draw.shadowed_centred(self, font, centre, MESSAGE_TOP, message, ViewConfig.TEXT_SMALL, ViewConfig.WHITE if bool(data.get("good", false)) else ViewConfig.RED)
	var hint_top := HINTS_TOP
	for line: String in data.get("hints", []):
		Draw.text_centred(self, font, centre, hint_top, line, ViewConfig.TEXT_SMALL, ViewConfig.GREY)
		hint_top += HINTS_STEP
