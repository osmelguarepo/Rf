extends Node2D
## The volume readout ("VOL 7/10", "MUTE"): a small label in the top right corner, shown for SHOW_SECONDS after the volume
## changes, over whatever screen is up.

const ViewConfig := preload("res://scripts/view/view_config.gd")
const Atlas := preload("res://scripts/view/atlas.gd")
const Draw := preload("res://scripts/view/draw.gd")

const SHOW_SECONDS := 1.5
const MARGIN := 8

var font: Font
var text := ""
var seconds_left := 0.0


func setup(p_atlas: Atlas) -> void:
	font = p_atlas.font
	z_index = 100
	visible = false


## Shows `p_text` for SHOW_SECONDS.
func show_text(p_text: String) -> void:
	text = p_text
	seconds_left = SHOW_SECONDS
	visible = true
	queue_redraw()


func _process(delta: float) -> void:
	if seconds_left > 0.0:
		seconds_left -= delta
		if seconds_left <= 0.0:
			visible = false


func _draw() -> void:
	if font == null or text == "":
		return
	var size := ViewConfig.TEXT_SMALL
	var width := Draw.text_width(font, text, size)
	var x := ViewConfig.VIEW_W - MARGIN - width
	draw_rect(Rect2(x - 4, MARGIN - 4, width + 8, size + 8), ViewConfig.BLACK)
	Draw.text(self, font, x, MARGIN, text, size, ViewConfig.WHITE)
