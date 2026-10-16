extends Node2D
## The game screen (src/scenes/GameScene.ts in the Phaser version): one World stepped by the app's fixed step, drawn
## by road.gd, cars.gd and hud.gd.
##
## Each frame runs the steps the app's clock gives, each with the input's bytes (one per seat: held controls plus any
## latched press).
## Stepping stops early in a frame that reaches stage clear or game over. At game over the world takes no input: a
## confirm press starts a new game (the next seed, the session's best as its high score) and a pause press goes back
## to the title. Presses latched before the game ended are dropped, so they cannot skip the game-over panel.
## Losing focus while running latches a pause press, which the next step takes.

const App := preload("res://scripts/app/app.gd")
const Config := preload("res://scripts/sim/config.gd")
const World := preload("res://scripts/sim/world.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")
const ViewConfig := preload("res://scripts/view/view_config.gd")
const Road := preload("res://scripts/view/road.gd")
const Cars := preload("res://scripts/view/cars.gd")
const Hud := preload("res://scripts/view/hud.gd")

var app: App
var cfg: Config = Config.standard()
var world: World
## Games started on this screen, counting the first.
var games: int = 0
## The event message and its seconds left (real time, as in Phaser).
var message: String = ""
var message_time: float = 0.0
var road: Road
var cars: Cars
var hud: Hud


## Builds the screen and starts the first game. The app calls it before adding the screen to the tree.
func setup(p_app: App) -> void:
	app = p_app
	road = $Road
	cars = $Cars
	hud = $Hud
	road.setup(app.atlas, cfg)
	cars.setup(app.atlas)
	hud.setup(app.atlas, cfg)
	new_game()


func new_game() -> void:
	world = World.new(cfg, app.next_seed(), 1, app.high_score)
	games += 1
	message = ""
	message_time = 0.0
	app.input.clear_presses()
	app.clock.reset()
	render()


func frame(steps: int, delta: float) -> void:
	if world.phase == World.GAME_OVER:
		var presses := app.input.take_presses()
		if PlayerInput.pause(presses):
			app.show_title()
			return
		if PlayerInput.confirm(presses):
			new_game()
			return
	else:
		for i in steps:
			step_once(app.input.step_bytes(world.players.size()))
			if world.phase == World.STAGE_CLEAR or world.phase == World.GAME_OVER:
				break
	message_time = maxf(0.0, message_time - delta)
	render()


## One step of the world with one input byte per seat, and what follows from it: messages, the session's best, and
## dropping presses when the game ends.
func step_once(bytes: PackedByteArray) -> void:
	var was_over := world.phase == World.GAME_OVER
	world.step(bytes)
	_handle_events(world.events)
	app.high_score = maxi(app.high_score, world.high_score)
	if world.phase == World.GAME_OVER and not was_over:
		app.input.clear_presses()


func on_focus_lost() -> void:
	if world != null and world.phase == World.RUNNING:
		app.input.press(PlayerInput.PAUSE)


func render() -> void:
	road.set_scroll(Cars.camera_px(world))
	cars.show_world(world)
	hud.show_world(world, app.high_score, message if message_time > 0.0 else "")


## The HUD message for a step's events (handleEvents in Phaser). Game over has its own panel, so no message.
static func message_for(events: int) -> String:
	if (events & World.EV_GAME_OVER) != 0:
		return ""
	if (events & World.EV_SPIN) != 0:
		return "SPIN OUT!"
	if (events & World.EV_CRASH) != 0:
		return "CRASH!"
	if (events & World.EV_SKID) != 0:
		return "OIL! STEER INTO THE SLIDE"
	if (events & World.EV_PICKUP) != 0:
		return "FUEL!"
	if (events & World.EV_PASS) != 0:
		return "PASS +50"
	return ""


func _handle_events(events: int) -> void:
	var text := message_for(events)
	if not text.is_empty():
		message = text
		message_time = ViewConfig.MESSAGE_SECONDS
