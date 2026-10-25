extends Node2D
## The title screen (src/scenes/TitleScene.ts in the Phaser version): the still road and title_view.gd's drawing.
##
## Three choices: LOCAL, the join screen (people on this machine with a gamepad, or the keyboard when playing alone, and
## bots in every empty seat); ONLINE, the login and the queue (login_screen.gd, queue_screen.gd; the private rooms of online.gd without an API); and RANKING. Up and Down (the arrow keys or W and S, a pad's D-pad or left stick: nav.gd) move between
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
const CHOICE_RANKING := 2

var app: App
var cfg: Config = Config.standard()
## Seconds since the screen opened.
var time: float = 0.0
## The choice shown: CHOICE_LOCAL or CHOICE_ONLINE.
var choice: int = CHOICE_LOCAL
var _starting := false
## True on the web until a key or a click: the title waits for it (browsers block sound before a gesture), shows PRESS ANY KEY and
## takes no input. A gamepad button is no gesture for Safari, so only a key or the mouse count (a tap makes a mouse click).
var waiting: bool = false
var road: Road
var view: TitleView


## Builds the screen. The app calls it before adding the screen to the tree.
func setup(p_app: App) -> void:
	app = p_app
	road = $Road
	view = $TitleView
	road.beside_panels = false
	road.setup(app.atlas, cfg)
	choice = clampi(app.title_choice, CHOICE_LOCAL, CHOICE_RANKING)
	view.setup(app.atlas, cfg, app.high_score)
	waiting = app.web_mode and not app.audio_unlocked
	view.set_waiting(waiting)
	view.set_web(app.web_mode)
	view.set_touch(app.touch.active)
	view.set_choice(choice)


func frame(_steps: int, delta: float) -> void:
	time += delta
	view.set_touch(app.touch.active)
	if waiting:
		app.nav.clear()
		app.input.clear_presses()
		view.set_prompt_bright(floori(time / ViewConfig.PROMPT_BLINK_SECONDS) % 2 == 0)
		return
	view.set_prompt_bright(floori(time / ViewConfig.PROMPT_BLINK_SECONDS) % 2 == 0)
	for command: Vector2i in app.nav.take():
		if command.y == Nav.UP:
			select(maxi(CHOICE_LOCAL, choice - 1))
		elif command.y == Nav.DOWN:
			select(mini(CHOICE_RANKING, choice + 1))
	if PlayerInput.confirm(app.input.take_presses()):
		start()


func on_focus_lost() -> void:
	pass


## Shows a choice without picking it.
func select(p_choice: int) -> void:
	choice = p_choice
	app.title_choice = choice
	view.set_choice(choice)


## Picks the choice shown: the join screen of LOCAL, the login or queue of ONLINE (the private rooms when there is no API), or the leaderboard.
func start() -> void:
	if _starting:
		return
	app.title_choice = choice
	_starting = true
	if choice == CHOICE_ONLINE:
		app.show_online_entry()
	elif choice == CHOICE_RANKING:
		app.show_ranking()
	else:
		app.show_join()


## The gesture arrived: the menu music starts and the title takes input. The press that did it is not a menu command.
func unlock() -> void:
	if not waiting:
		return
	waiting = false
	app.audio_unlocked = true
	app.nav.clear()
	app.input.clear_presses()
	view.set_waiting(false)
	if app.audio != null:
		app.audio.music("music_menu")


func _unhandled_input(event: InputEvent) -> void:
	if waiting:
		var key := event as InputEventKey
		var click := event as InputEventMouseButton
		if (key != null and key.pressed and not key.echo) or (click != null and click.pressed):
			unlock()
		return
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
	elif Rect2(ViewConfig.RANKING_BUTTON).has_point(at):
		select(CHOICE_RANKING)
		start()
