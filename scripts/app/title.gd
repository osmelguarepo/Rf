extends Node2D
## The title screen (src/scenes/TitleScene.ts in the Phaser version): the still road and title_view.gd's drawing.
##
## Two modes: LOCAL, the join screen (people on this machine with a gamepad, or the keyboard when playing alone, and
## bots in every empty seat), and ONLINE, humans only, which is not built yet: choosing it does nothing. Up and Down (the arrow keys or W and S, a pad's D-pad or left stick: nav.gd) move between
## them; a confirm press (Enter, Space, pad A or Start) picks the one shown, as does a click or tap on its button. The
## app remembers the last choice for the next time the title opens. The prompt blinks every half second of real time.

const App := preload("res://scripts/app/app.gd")
const Config := preload("res://scripts/sim/config.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")
const Nav := preload("res://scripts/input/nav.gd")
const ViewConfig := preload("res://scripts/view/view_config.gd")
const Road := preload("res://scripts/view/road.gd")
const TitleView := preload("res://scripts/view/title_view.gd")

## The choices, top to bottom (ViewConfig.TITLE_CHOICES).
const CHOICE_LOCAL := 0
const CHOICE_ONLINE := 1

var app: App
var cfg: Config = Config.standard()
## Seconds since the screen opened.
var time: float = 0.0
## The choice shown: CHOICE_LOCAL or CHOICE_ONLINE.
var choice: int = CHOICE_LOCAL
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
	choice = clampi(app.title_choice, CHOICE_LOCAL, CHOICE_ONLINE)
	view.setup(app.atlas, cfg, app.high_score)
	view.set_choice(choice)


func frame(_steps: int, delta: float) -> void:
	time += delta
	view.set_prompt_bright(floori(time / ViewConfig.PROMPT_BLINK_SECONDS) % 2 == 0)
	for command: Vector2i in app.nav.take():
		if command.y == Nav.UP:
			select(CHOICE_LOCAL)
		elif command.y == Nav.DOWN:
			select(CHOICE_ONLINE)
	if PlayerInput.confirm(app.input.take_presses()):
		start()


func on_focus_lost() -> void:
	pass


## Shows a choice without picking it.
func select(p_choice: int) -> void:
	choice = p_choice
	app.title_choice = choice
	view.set_choice(choice)


## Picks the choice shown: the join screen of LOCAL. ONLINE is not built yet and does nothing.
func start() -> void:
	if _starting:
		return
	app.title_choice = choice
	if choice == CHOICE_ONLINE:
		return
	_starting = true
	app.show_join()


func _unhandled_input(event: InputEvent) -> void:
	var at := Vector2(-1, -1)
	var mouse := event as InputEventMouseButton
	if mouse != null and mouse.pressed and mouse.button_index == MOUSE_BUTTON_LEFT:
		at = mouse.position
	var touch := event as InputEventScreenTouch
	if touch != null and touch.pressed:
		at = touch.position
	if Rect2(ViewConfig.START_BUTTON).has_point(at):
		select(CHOICE_LOCAL)
		start()
	elif Rect2(ViewConfig.VERSUS_BUTTON).has_point(at):
		select(CHOICE_ONLINE)
		start()
