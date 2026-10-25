extends Node2D
## Draws the touch controls (scripts/input/touch.gd) over whatever screen is up: translucent round and square buttons, lit while
## a finger holds them, and in a portrait window a notice asking for the device to be turned (the game is 16:9).

const ViewConfig := preload("res://scripts/view/view_config.gd")
const Atlas := preload("res://scripts/view/atlas.gd")
const Draw := preload("res://scripts/view/draw.gd")
const Touch := preload("res://scripts/input/touch.gd")

const FILL_ALPHA := 0.4
const FILL_HELD_ALPHA := 0.75
const RIM_ALPHA := 0.8
const ROTATE_TEXT := "TURN YOUR DEVICE"
const ROTATE_TEXT_2 := "TO PLAY"

var touch: Touch
var font: Font
## True when the window is taller than wide.
var portrait: bool = false
var _signature := ""


func setup(p_touch: Touch, p_atlas: Atlas) -> void:
	touch = p_touch
	font = p_atlas.font
	z_index = 100
	visible = false


func _process(_delta: float) -> void:
	if touch == null:
		return
	var window := get_window()
	var tall := window != null and window.size.y > window.size.x
	var held := PackedStringArray()
	for button: Dictionary in touch.buttons():
		if touch.is_held(button["id"]):
			held.append(String(button["id"]))
	var signature := "%s|%s|%s|%s" % [touch.active, touch.mode, tall, ",".join(held)]
	if signature == _signature:
		return
	_signature = signature
	portrait = tall
	visible = touch.active
	queue_redraw()


func _draw() -> void:
	if touch == null or font == null or not touch.active:
		return
	if portrait:
		_draw_rotate_notice()
		return
	for button: Dictionary in touch.buttons():
		_draw_button(button, touch.is_held(button["id"]))


func _draw_button(button: Dictionary, held: bool) -> void:
	var fill := Color(ViewConfig.BLACK, FILL_HELD_ALPHA if held else FILL_ALPHA)
	var rim := Color(ViewConfig.YELLOW if held else ViewConfig.WHITE, RIM_ALPHA)
	var label: String = button["label"]
	var centre: Vector2
	if button.has("rect"):
		var rect: Rect2 = button["rect"]
		draw_rect(rect, fill)
		draw_rect(rect, rim, false, 2.0)
		centre = rect.get_center()
	else:
		centre = button["centre"]
		draw_circle(centre, float(button["radius"]), fill)
		draw_arc(centre, float(button["radius"]), 0.0, TAU, 32, rim, 2.0)
	var size := ViewConfig.TEXT_MEDIUM if label.length() == 1 else ViewConfig.TEXT_SMALL
	var colour := Color(ViewConfig.YELLOW if held else ViewConfig.WHITE, 0.95)
	Draw.text_centred(self, font, roundi(centre.x), roundi(centre.y) - (size >> 1), label, size, colour)


func _draw_rotate_notice() -> void:
	draw_rect(Rect2(0, 0, ViewConfig.VIEW_W, ViewConfig.VIEW_H), Color(ViewConfig.BLACK, 0.9))
	var medium := ViewConfig.TEXT_MEDIUM
	var centre := ViewConfig.VIEW_W >> 1
	Draw.shadowed_centred(self, font, centre, 140, ROTATE_TEXT, medium, ViewConfig.YELLOW)
	Draw.shadowed_centred(self, font, centre, 168, ROTATE_TEXT_2, medium, ViewConfig.WHITE)
