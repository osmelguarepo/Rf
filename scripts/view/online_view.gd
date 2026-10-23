extends Node2D
## The private-room screen's drawing (docs/SPEC_ONLINE.md §16.4): over the dimmed road, the title, then what the screen is
## doing. The menu has four rows (NAME, CREATE ROOM, JOIN ROOM, CODE); the waiting room lists the six seats under the code;
## the other states are a line of text. online.gd decides everything and hands this a Dictionary:
##   {"step", "rows", "focus", "editing", "name", "code", "message", "room_code", "seat_names", "seat", "owner", "time"}

const ViewConfig := preload("res://scripts/view/view_config.gd")
const Atlas := preload("res://scripts/view/atlas.gd")
const Draw := preload("res://scripts/view/draw.gd")
const PlayerColours := preload("res://scripts/view/player_colours.gd")

const TITLE := "ONLINE"
const TITLE_TOP := 14
const SUBTITLE := "PRIVATE ROOMS: NO RANKING POINTS"
const SUBTITLE_TOP := 54
const ROWS_TOP := 100
const ROW_STEP := 34
const ROW_W := 360
const ROW_H := 26
const MESSAGE_TOP := 250
const HINTS_TOP := 296
const HINTS_STEP := 16
const SEAT_TOP := 118
const SEAT_STEP := 24
## The cursor of an edited field blinks this often, in seconds.
const BLINK_SECONDS := 0.5

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


## The text of a menu row's value, with the cursor when it is being edited.
static func row_text(row_label: String, value: String, editing: bool, cursor_on: bool) -> String:
	if value.is_empty() and not editing:
		return row_label
	return "%s  %s%s" % [row_label, value, "_" if editing and cursor_on else ""]


func _draw() -> void:
	if font == null or data.is_empty():
		return
	var centre := ViewConfig.VIEW_W >> 1
	Draw.rect(self, Rect2i(0, 0, ViewConfig.VIEW_W, ViewConfig.VIEW_H), Color(0, 0, 0, ViewConfig.OVERLAY_DIM))
	Draw.shadowed_centred(self, font, centre, TITLE_TOP, TITLE, ViewConfig.TEXT_HUGE, ViewConfig.YELLOW)
	Draw.text_centred(self, font, centre, SUBTITLE_TOP, SUBTITLE, ViewConfig.TEXT_SMALL, ViewConfig.WHITE)
	match data["step"]:
		"menu":
			_draw_menu(centre)
		"lobby":
			_draw_lobby(centre)
		_:
			Draw.shadowed_centred(self, font, centre, 150, String(data["message"]), ViewConfig.TEXT_MEDIUM, ViewConfig.WHITE)
	var top := HINTS_TOP
	for line: String in data.get("hints", []):
		Draw.text_centred(self, font, centre, top, line, ViewConfig.TEXT_SMALL, ViewConfig.WHITE)
		top += HINTS_STEP


func _draw_menu(centre: int) -> void:
	var rows: Array = data["rows"]
	var lit := floori(float(data["time"]) / BLINK_SECONDS) % 2 == 0
	for i in rows.size():
		var focused: bool = i == int(data["focus"])
		var r := row_rect(i)
		Draw.box(self, r, ViewConfig.YELLOW if focused else ViewConfig.GREY, 0.0)
		var editing: bool = focused and bool(data["editing"])
		var text := row_text(String(rows[i]), "", false, false)
		if i == 0:
			text = row_text("NAME", String(data["name"]), editing, lit)
		elif i == 3:
			text = row_text("CODE", String(data["code"]), editing, lit)
		Draw.text_centred(self, font, centre, r.position.y + 9, text, ViewConfig.TEXT_SMALL, ViewConfig.YELLOW if focused else ViewConfig.WHITE)
	var message := String(data["message"])
	if not message.is_empty():
		Draw.shadowed_centred(self, font, centre, MESSAGE_TOP, message, ViewConfig.TEXT_SMALL, ViewConfig.RED)


func _draw_lobby(centre: int) -> void:
	Draw.shadowed_centred(self, font, centre, 76, "ROOM  %s" % String(data["room_code"]), ViewConfig.TEXT_LARGE, ViewConfig.WHITE)
	var names: PackedStringArray = data["seat_names"]
	for i in names.size():
		var text := names[i] if not names[i].is_empty() else "BOT"
		var mine: bool = i == int(data["seat"])
		var colour: Color = PlayerColours.colour(i) if names[i] != "" else ViewConfig.GREY
		Draw.text_centred(self, font, centre, SEAT_TOP + i * SEAT_STEP, "%d  %s%s" % [i + 1, text, "  (YOU)" if mine else ""], ViewConfig.TEXT_SMALL, colour)
	var prompt := "PRESS ENTER TO START" if bool(data["owner"]) else "WAITING FOR THE OWNER"
	Draw.shadowed_centred(self, font, centre, MESSAGE_TOP, prompt, ViewConfig.TEXT_SMALL, ViewConfig.YELLOW)
