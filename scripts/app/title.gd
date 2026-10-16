extends Node2D
## The title screen (src/scenes/TitleScene.ts in the Phaser version): the still road and title_view.gd's drawing.
## A confirm press (Enter, Space, pad A or Start), or a click or tap on START, starts a game. The prompt blinks
## every half second of real time.

const App := preload("res://scripts/app/app.gd")
const Config := preload("res://scripts/sim/config.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")
const ViewConfig := preload("res://scripts/view/view_config.gd")
const Road := preload("res://scripts/view/road.gd")
const TitleView := preload("res://scripts/view/title_view.gd")

var app: App
var cfg: Config = Config.standard()
## Seconds since the screen opened.
var time: float = 0.0
var _starting := false
var road: Road
var view: TitleView


## Builds the screen. The app calls it before adding the screen to the tree.
func setup(p_app: App) -> void:
	app = p_app
	road = $Road
	view = $TitleView
	road.beside_panels = false
	road.setup(app.atlas, cfg)
	view.setup(app.atlas, cfg, app.high_score)


func frame(_steps: int, delta: float) -> void:
	time += delta
	view.set_prompt_bright(floori(time / ViewConfig.PROMPT_BLINK_SECONDS) % 2 == 0)
	if PlayerInput.confirm(app.input.take_presses()):
		start()


func on_focus_lost() -> void:
	pass


func start() -> void:
	if _starting:
		return
	_starting = true
	app.start_game()


func _unhandled_input(event: InputEvent) -> void:
	var at := Vector2(-1, -1)
	var mouse := event as InputEventMouseButton
	if mouse != null and mouse.pressed and mouse.button_index == MOUSE_BUTTON_LEFT:
		at = mouse.position
	var touch := event as InputEventScreenTouch
	if touch != null and touch.pressed:
		at = touch.position
	if Rect2(ViewConfig.START_BUTTON).has_point(at):
		start()
