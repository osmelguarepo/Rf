extends Node2D
## The title screen's drawing (create() in src/scenes/TitleScene.ts, Phaser version), laid out for 16:9: the title
## over the road, keyboard and gamepad controls in boxes on the grass either side, the two modes (LOCAL and
## ONLINE) with the one shown lit, the player's car in its start lane, a blinking prompt, and the best score this
## session with the fullscreen keys. The road behind is a road.gd node.

const ViewConfig := preload("res://scripts/view/view_config.gd")
const Atlas := preload("res://scripts/view/atlas.gd")
const Draw := preload("res://scripts/view/draw.gd")
const Config := preload("res://scripts/sim/config.gd")
const Traffic := preload("res://scripts/sim/traffic.gd")

var atlas: Atlas
var font: Font
var cfg: Config
var best: int = 0
## The prompt is drawn at full alpha when true, dimmed when false.
var prompt_bright: bool = true
## The choice drawn lit: an index of ViewConfig.TITLE_CHOICES.
var choice: int = 0
## True on the web before the first key or click: the prompt band asks for it instead of the controls.
var waiting: bool = false
## True in the browser: the fullscreen hint names F, since the browser keeps F11.
var web: bool = false
## True on a touch device: the prompts name taps.
var touch: bool = false


func setup(p_atlas: Atlas, p_cfg: Config, p_best: int) -> void:
	atlas = p_atlas
	font = p_atlas.font
	cfg = p_cfg
	best = p_best
	queue_redraw()


func set_prompt_bright(bright: bool) -> void:
	if bright != prompt_bright:
		prompt_bright = bright
		queue_redraw()


func set_web(p_web: bool) -> void:
	if p_web != web:
		web = p_web
		queue_redraw()


func set_touch(p_touch: bool) -> void:
	if p_touch != touch:
		touch = p_touch
		queue_redraw()


func set_waiting(p_waiting: bool) -> void:
	if p_waiting != waiting:
		waiting = p_waiting
		queue_redraw()


func set_choice(p_choice: int) -> void:
	if p_choice != choice:
		choice = p_choice
		queue_redraw()


## The buttons of the choices, in ViewConfig.TITLE_CHOICES order.
static func choice_buttons() -> Array[Rect2i]:
	return [ViewConfig.START_BUTTON, ViewConfig.VERSUS_BUTTON, ViewConfig.RANKING_BUTTON]


## Hitbox of the still player car: its start lane, its top at TITLE_CAR_TOP.
static func car_box(c: Config) -> Rect2i:
	var x := Traffic.lane_x(c, c.start_lane, c.player_w)
	return Rect2i(floori(x + 0.5), ViewConfig.TITLE_CAR_TOP, roundi(c.player_w), roundi(c.player_h))


func _draw() -> void:
	if font == null or cfg == null:
		return
	var centre := ViewConfig.VIEW_W >> 1
	var box := car_box(cfg)
	Draw.sprite_on_hitbox(self, atlas, ViewConfig.PLAYER, box.position, box.size, ViewConfig.PLAYER_FALLBACK)

	Draw.shadowed_centred(self, font, centre, ViewConfig.TITLE_TOP, ViewConfig.TITLE, ViewConfig.TEXT_HUGE, ViewConfig.YELLOW)
	if not touch:
		_draw_controls(ViewConfig.CONTROLS_LEFT, "KEYBOARD", ViewConfig.CONTROLS_KEYBOARD)
		_draw_controls(ViewConfig.CONTROLS_RIGHT, "GAMEPAD", ViewConfig.CONTROLS_PAD)

	var buttons := choice_buttons()
	for i in buttons.size():
		_draw_button(buttons[i], ViewConfig.TITLE_CHOICES[i], i == choice)
	var small := ViewConfig.TEXT_SMALL

	var text_dy := (ViewConfig.BAND_H - small) >> 1
	for band_y: int in [ViewConfig.PROMPT_BAND_Y, ViewConfig.BEST_BAND_Y]:
		Draw.rect(self, Rect2i(0, band_y, ViewConfig.VIEW_W, ViewConfig.BAND_H), Color(0, 0, 0, ViewConfig.BAND_ALPHA))
	var prompt_colour := Color(ViewConfig.WHITE, 1.0 if prompt_bright else ViewConfig.PROMPT_DIM_ALPHA)
	if waiting:
		var medium := ViewConfig.TEXT_MEDIUM
		Draw.text_centred(self, font, centre, ViewConfig.PROMPT_BAND_Y + ((ViewConfig.BAND_H - medium) >> 1), (ViewConfig.PROMPT_WEB_TOUCH if touch else ViewConfig.PROMPT_WEB), medium, prompt_colour)
	else:
		Draw.text_centred(self, font, centre, ViewConfig.PROMPT_BAND_Y + text_dy, (ViewConfig.PROMPT_TOUCH if touch else ViewConfig.PROMPT), small, prompt_colour)
	var quarter := ViewConfig.VIEW_W >> 2
	var best_top := ViewConfig.BEST_BAND_Y + text_dy
	Draw.text_centred(self, font, quarter, best_top, "BEST THIS SESSION: %d" % best, small, ViewConfig.GREY)
	Draw.text_centred(self, font, centre + quarter, best_top, (ViewConfig.FULLSCREEN_HINT_TOUCH if touch else (ViewConfig.FULLSCREEN_HINT_WEB if web else ViewConfig.FULLSCREEN_HINT)), small, ViewConfig.GREY)


## A choice's button: lit (red with a light-red rim, white label) when it is the one shown, dark otherwise.
func _draw_button(button: Rect2i, label: String, lit: bool) -> void:
	Draw.rect(self, button, ViewConfig.LIGHT_RED if lit else ViewConfig.GREY)
	Draw.rect(self, button.grow(-2), ViewConfig.RED if lit else ViewConfig.BLACK)
	var label_top := button.position.y + ((button.size.y - ViewConfig.TEXT_MEDIUM) >> 1)
	var colour := ViewConfig.WHITE if lit else ViewConfig.GREY
	Draw.shadowed_centred(self, font, button.get_center().x, label_top, label, ViewConfig.TEXT_MEDIUM, colour)


func _draw_controls(r: Rect2i, heading: String, lines: Array) -> void:
	Draw.box(self, r)
	var x := r.position.x + ViewConfig.CONTROLS_PADDING
	var y := r.position.y + ViewConfig.CONTROLS_PADDING + 4
	Draw.text(self, font, x, y, heading, ViewConfig.TEXT_MEDIUM, ViewConfig.YELLOW)
	y = r.position.y + ViewConfig.CONTROLS_LINES_DY
	for line: String in lines:
		Draw.text(self, font, x, y, line, ViewConfig.TEXT_SMALL, ViewConfig.WHITE)
		y += ViewConfig.CONTROLS_LINE_STEP
