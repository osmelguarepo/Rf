extends "res://tests/test_case.gd"
## The app layer (scripts/app/, docs/GODOT_PLAN.md §3, §5): the main scene, boot, screen switching, the game
## screen's loop (steps, game over, retry, back to the title), the pause on focus loss, seeds and the self test.
## Each test boots a real App from scenes/boot.tscn in the runner's scene tree and frees it afterwards; frames are
## driven by calling the screens' frame() directly, as App._process() does.

const App := preload("res://scripts/app/app.gd")
const FixedStep := preload("res://scripts/app/fixed_step.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")
const World := preload("res://scripts/sim/world.gd")
const ViewConfig := preload("res://scripts/view/view_config.gd")

const BOOT := "res://scenes/boot.tscn"
const DT := 1.0 / 60.0

var app: App


func after_each() -> void:
	if app != null:
		app.get_parent().remove_child(app)
		app.free()
		app = null


func test_the_main_scene_is_the_boot_scene_with_the_app() -> void:
	assert_eq(ProjectSettings.get_setting("application/run/main_scene"), BOOT)
	var scene := load(BOOT) as PackedScene
	assert_not_null(scene)
	var root := scene.instantiate()
	assert_eq(root.get_script(), App)
	root.free()


func test_the_screens_are_scenes_with_their_scripts() -> void:
	var expected := {
		"res://scenes/title.tscn": ["res://scripts/app/title.gd", {
			"Road": "res://scripts/view/road.gd", "TitleView": "res://scripts/view/title_view.gd"
		}],
		"res://scenes/game.tscn": ["res://scripts/app/game.gd", {
			"Road": "res://scripts/view/road.gd", "Cars": "res://scripts/view/cars.gd", "Hud": "res://scripts/view/hud.gd"
		}],
	}
	for path: String in expected:
		var screen := (load(path) as PackedScene).instantiate()
		assert_eq((screen.get_script() as Script).resource_path, expected[path][0], path)
		var children: Dictionary = expected[path][1]
		for child: String in children:
			var node := screen.get_node_or_null(child)
			assert_true(node != null and (node.get_script() as Script).resource_path == children[child], "%s/%s" % [path, child])
		for method: String in ["setup", "frame", "on_focus_lost"]:
			assert_true(screen.has_method(method), "%s has %s()" % [path, method])
		screen.free()


func test_boot_loads_the_art_and_opens_the_title() -> void:
	_boot()
	assert_true(app.booted)
	assert_gt(app.atlas.frames.size(), 70)
	assert_true(app.atlas.has_frame("truck") and app.atlas.has_frame("oil_puddle"))
	assert_eq(_screen_name(), "Title")
	assert_true(InputMap.has_action("kb_confirm"), "the input map is built at boot")


func test_a_confirm_press_on_the_title_starts_a_game() -> void:
	_boot()
	app.current_screen().frame(0, DT)
	assert_eq(_screen_name(), "Title", "nothing pressed")
	app.input.press(PlayerInput.PAUSE)
	app.current_screen().frame(1, DT)
	assert_eq(_screen_name(), "Title", "pause does not start")
	app.input.press(PlayerInput.CONFIRM)
	app.current_screen().frame(0, DT)
	assert_eq(_screen_name(), "Game")
	assert_eq(app.current_screen().world.game_seed, 77)


func test_a_click_on_start_starts_a_game() -> void:
	_boot()
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = Vector2(ViewConfig.START_BUTTON.get_center())
	app.current_screen()._unhandled_input(click)
	assert_eq(_screen_name(), "Game")


func test_input_events_reach_the_app() -> void:
	_boot()
	var enter := InputEventKey.new()
	enter.physical_keycode = KEY_ENTER
	enter.pressed = true
	app._input(enter)
	assert_eq(app.input.pending, PlayerInput.CONFIRM)


## The game screen steps the world once per fixed step, with the latched presses on the first step only.
func test_the_game_runs_the_clocks_steps() -> void:
	var game := _start_game()
	var world: World = game.world
	game.frame(0, DT)
	assert_eq(world.tick, 0)
	game.frame(3, DT * 3.0)
	assert_eq(world.tick, 3)
	app.input.press(PlayerInput.PAUSE)
	game.frame(2, DT * 2.0)
	assert_eq(world.phase, World.PAUSED, "the press paused on the first step")
	assert_eq(world.tick, 5, "the second step ran too, and did not resume")
	app.input.press(PlayerInput.PAUSE)
	game.frame(1, DT)
	assert_eq(world.phase, World.RUNNING)


## NOTIFICATION_APPLICATION_FOCUS_OUT pauses a running game on its next step; it does nothing to a paused one.
func test_losing_focus_pauses_a_running_game() -> void:
	var game := _start_game()
	var world: World = game.world
	game.frame(2, DT)
	app.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	assert_eq(world.phase, World.RUNNING, "nothing happens until a step")
	game.frame(0, DT)
	assert_eq(world.phase, World.RUNNING, "a frame with no step keeps the press")
	game.frame(1, DT)
	assert_eq(world.phase, World.PAUSED)
	app.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	game.frame(1, DT)
	assert_eq(world.phase, World.PAUSED, "a second focus loss does not resume")
	app.notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
	game.frame(1, DT)
	assert_eq(world.phase, World.PAUSED, "getting focus back does not resume either")


func test_game_over_then_confirm_retries_with_the_next_seed() -> void:
	var game := _start_game()
	var first: World = game.world
	first.player().fuel = 0.01
	game.frame(3, DT * 3.0)
	assert_eq(first.phase, World.GAME_OVER)
	assert_eq(first.tick, 1, "stepping stops at game over")
	game.frame(1, DT)
	assert_eq(game.world, first, "the game-over panel waits for a press")
	app.input.press(PlayerInput.CONFIRM)
	game.frame(1, DT)
	var second: World = game.world
	assert_ne(second, first)
	assert_eq(second.game_seed, first.game_seed + 1)
	assert_eq(second.phase, World.RUNNING)
	assert_eq(game.games, 2)


func test_game_over_then_pause_goes_back_to_the_title() -> void:
	var game := _start_game()
	game.world.player().fuel = 0.01
	game.frame(1, DT)
	app.input.press(PlayerInput.PAUSE | PlayerInput.CONFIRM)
	game.frame(1, DT)
	assert_eq(_screen_name(), "Title", "Start (pause and confirm) goes to the title")


## The session's best score carries into the next game and the title.
func test_the_best_score_carries_over() -> void:
	var game := _start_game()
	game.world.player().score = 4321
	game.world.player().fuel = 0.01
	game.frame(1, DT)
	assert_eq(app.high_score, 4321)
	app.input.press(PlayerInput.CONFIRM)
	game.frame(1, DT)
	assert_eq(game.world.high_score, 4321, "the new game starts with the session's best")
	app.show_title()
	assert_eq(app.current_screen().get_node("TitleView").best, 4321)


func test_a_stage_clear_waits_for_confirm() -> void:
	var game := _start_game()
	var world: World = game.world
	world.player().y_world = world.goal - 0.01
	world.player().speed = 100.0
	game.frame(4, DT * 4.0)
	assert_eq(world.phase, World.STAGE_CLEAR)
	assert_eq(world.tick, 1, "stepping stops at stage clear")
	game.frame(1, DT)
	assert_eq(world.phase, World.STAGE_CLEAR)
	app.input.press(PlayerInput.CONFIRM)
	game.frame(1, DT)
	assert_eq(world.stage, 2)
	assert_eq(world.phase, World.RUNNING)


func test_event_messages_last_one_second() -> void:
	var game := _start_game()
	game.world.player().x = game.world.cfg.road_left
	game.world.player().speed = 100.0
	game.frame(1, DT)
	game.world.player().slide_vx = -1.0
	game.frame(1, DT)
	assert_eq(game.message, "SPIN OUT!")
	assert_eq(game.message_time, ViewConfig.MESSAGE_SECONDS - DT)
	for i in 70:
		game.frame(0, DT)
	assert_eq(game.message_time, 0.0)


func test_seeds_follow_the_override_then_count_up() -> void:
	app = (load(BOOT) as PackedScene).instantiate() as App
	app.seed_override = 5
	assert_eq([app.next_seed(), app.next_seed(), app.next_seed()], [5, 6, 7])
	app.free()
	app = null


## The checks of the self test pass in process. (--selftest runs them, then draws frames of a game and quits.)
func test_the_self_test_passes() -> void:
	_boot()
	assert_eq(app.selftest_problems(), PackedStringArray())
	assert_eq(_screen_name(), "Title", "it ends on the title")


func test_the_selftest_input_pauses_and_resumes() -> void:
	var pauses := 0
	for tick in App.SELFTEST_TICKS:
		if PlayerInput.pause(App.selftest_byte(tick)):
			pauses += 1
	assert_eq(pauses, 2)


# --- helpers ---------------------------------------------------------------------------------------------------------


## Boots an app as the engine would. The runner's root is not in the tree yet, so _ready() does not come: start().
func _boot() -> void:
	app = (load(BOOT) as PackedScene).instantiate() as App
	app.seed_override = 77
	(Engine.get_main_loop() as SceneTree).root.add_child(app)
	app.start()


func _screen_name() -> String:
	return String(app.current_screen().name)


func _start_game() -> Node:
	_boot()
	return app.start_game()
