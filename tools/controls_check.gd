extends "res://tools/tool_base.gd"
## Checks every control the title screen lists (ViewConfig.CONTROLS_KEYBOARD and CONTROLS_PAD) through the real app:
## the key or button is sent as the driver sends it (Input.parse_input_event()), the screens run frame by frame, and the
## effect is read from the game's own state. It prints one line per control, and ends with "controls_check: PASS" only
## if every one did what the title says. It also checks the hints on the join screen and the pause and game-over panels,
## and the developer dashboard (F1, with --admin).
##
##   godot --headless --fixed-fps 60 --path . -s res://tools/controls_check.gd
##
## Keyboard: the title (Up/W and Down/S pick a mode, Enter, Space and keypad Enter start), the join screen (Enter seats
## the keyboard, Enter again starts), and the race (throttle, nitro, brake, steer, pause), both in a versus race and in
## the single-player game. Pad: the same on a pad seated with A.

const Seats := preload("res://scripts/input/seats.gd")
const Match := preload("res://scripts/sim/match.gd")

const PAD := 0
const WAIT_FRAMES := 900

var _failed := 0
var _checked := 0
var _pad_mode := false


func _initialize() -> void:
	if not begin():
		quit(1)
		return
	start_app(7)
	await _frames(5)
	await _title_keyboard()
	await _race_keyboard_versus()
	await _race_keyboard_solo()
	await _pad_versus()
	await _pad_solo()
	await _panels()
	await _admin()
	print("controls_check: %d checked, %d failed" % [_checked, _failed])
	finish(1 if _failed > 0 else 0, "controls_check: PASS")


func _frames(n: int) -> void:
	for i in n:
		await process_frame


## Prints and counts one control: `ok` is whether it did what the title says.
func _expect(what: String, ok: bool, detail: String = "") -> void:
	_checked += 1
	if not ok:
		_failed += 1
	print("%s  %s%s" % ["ok  " if ok else "FAIL", what, ("  (" + detail + ")") if not ok and detail != "" else ""])


func _screen_name() -> String:
	var screen := app.current_screen()
	return String(screen.name) if screen != null else ""


# --- Title ---------------------------------------------------------------------------------------------------------


func _title_keyboard() -> void:
	print("-- keyboard: title")
	for pair: Array in [[KEY_DOWN, "DOWN"], [KEY_S, "S"]]:
		app.title_choice = 0
		app.show_title()
		await _frames(3)
		tap(pair[0])
		await _frames(3)
		_expect("title: %s picks ONLINE" % pair[1], app.title_choice == 1, "title_choice=%d" % app.title_choice)
	for pair: Array in [[KEY_UP, "UP"], [KEY_W, "W"]]:
		app.title_choice = 1
		app.show_title()
		await _frames(3)
		tap(pair[0])
		await _frames(3)
		_expect("title: %s picks LOCAL" % pair[1], app.title_choice == 0, "title_choice=%d" % app.title_choice)
	for pair: Array in [[KEY_ENTER, "ENTER"], [KEY_SPACE, "SPACE"], [KEY_KP_ENTER, "KP ENTER"]]:
		app.title_choice = 0
		app.show_title()
		await _frames(3)
		tap(pair[0])
		await _frames(3)
		_expect("title: %s starts (join screen)" % pair[1], _screen_name() == "Join", _screen_name())
	app.title_choice = 0
	app.show_title()
	await _frames(3)
	tap(KEY_DOWN)
	await _frames(3)
	tap(KEY_DOWN)
	await _frames(3)
	_expect("title: DOWN twice picks RANKING", app.title_choice == 2, "title_choice=%d" % app.title_choice)
	tap(KEY_ENTER)
	await _frames(3)
	_expect("title: ENTER on RANKING opens the leaderboard", _screen_name() == "Ranking", _screen_name())
	tap(KEY_ESCAPE)
	await _frames(3)
	_expect("leaderboard: ESC returns to the title", _screen_name() == "Title", _screen_name())
	app.title_choice = 0
	app.show_title()
	await _frames(3)


# --- Race helpers --------------------------------------------------------------------------------------------------


func _device() -> int:
	return PAD if _pad_mode else Seats.KEYBOARD_DEVICE


## The car the person drives, on the versus or the single-player screen.
func _car() -> Car:
	var screen := app.current_screen()
	if screen == null:
		return null
	if screen.name == "Game":
		return screen.world.players[0]
	if screen.name == "Versus":
		var slot: int = (screen.lineup as Array).find(app.seats.seat_of(_device()))
		return screen.world.players[slot] if slot >= 0 else null
	return null


func _world() -> World:
	var screen := app.current_screen()
	return screen.world if screen != null and "world" in screen else null


## Waits until the world runs (a versus round past its countdown).
func _wait_running() -> bool:
	for i in WAIT_FRAMES:
		var w := _world()
		var screen := app.current_screen()
		var racing := w != null and w.phase == World.RUNNING and w.countdown == 0
		if screen != null and screen.name == "Versus":
			racing = racing and (screen.game_match as Match).phase == Match.PLAYING
		if racing and _car() != null:
			return true
		await process_frame
	return false


## Holds some controls for `n` frames, then lets go.
func _hold(downs: Array, ups: Array, n: int) -> void:
	for d: Callable in downs:
		d.call()
	await _frames(n)
	for u: Callable in ups:
		u.call()
	await _frames(2)


func _k(code: Key, pressed: bool) -> Callable:
	return func() -> void: key(code, pressed)


func _b(button: JoyButton, pressed: bool) -> Callable:
	return func() -> void: pad_button(PAD, button, pressed)


func _axis(axis: JoyAxis, value: float) -> Callable:
	return func() -> void: pad_axis(PAD, axis, value)


## Restarts the round (a new match, or a new game) and waits until it runs, so each control is tried from a standing
## start, before the bots pull the camera away (a car left behind is pushed along by the bottom edge, which would hide
## a brake or a steer). Returns false if it never runs.
func _fresh() -> bool:
	var screen := app.current_screen()
	if screen.name == "Versus":
		screen.new_match()
	else:
		screen.new_game()
	return await _wait_running()


## One control group in the race the app shows now. `ctl` is a dictionary: throttle/nitro/brake/left/right/pause
## each as [down Callable, up Callable, label]. Every control is tried on a fresh start, within the first 100 ticks.
func _race_checks(ctl: Dictionary, who: String) -> void:
	if not await _fresh():
		_expect("%s: the race runs" % who, false, "never reached RUNNING")
		return
	var go: Array = ctl["throttle"][0]
	# Throttle: every throttle control speeds the car up from a stop.
	for t: Array in ctl["throttle"]:
		await _fresh()
		var car := _car()
		await _hold([t[0]], [t[1]], 40)
		_expect("%s: %s throttle" % [who, t[2]], car.speed > 5.0, "speed %.1f" % car.speed)
	# Nitro: the car is in nitro gear while it is held, and it accelerates.
	var n: Array = ctl["nitro"]
	await _fresh()
	var ncar := _car()
	n[0].call()
	await _frames(40)
	_expect("%s: %s nitro (gear)" % [who, n[2]], ncar.gear == Car.GEAR_NITRO, "gear=%d" % ncar.gear)
	_expect("%s: %s nitro (throttle too)" % [who, n[2]], ncar.speed > 5.0, "speed %.1f" % ncar.speed)
	n[1].call()
	await _frames(4)
	_expect("%s: %s released, back to low gear" % [who, n[2]], ncar.gear == Car.GEAR_LOW, "gear=%d" % ncar.gear)
	# Brake: from speed, braking slows the car.
	for b: Array in ctl["brake"]:
		await _fresh()
		var car := _car()
		go[0].call()
		await _frames(50)
		go[1].call()
		var before := car.speed
		await _hold([b[0]], [b[1]], 12)
		_expect("%s: %s brake" % [who, b[2]], car.speed < before - 5.0, "speed %.1f -> %.1f" % [before, car.speed])
	# Steering: needs speed.
	for side: String in ["left", "right"]:
		for s: Array in ctl[side]:
			await _fresh()
			var car := _car()
			go[0].call()
			await _frames(40)
			var x0 := car.x
			await _hold([s[0]], [s[1]], 12)
			go[1].call()
			var moved := car.x - x0
			var good := moved < -1.0 if side == "left" else moved > 1.0
			_expect("%s: %s steer %s" % [who, s[2], side], good, "x moved %.1f" % moved)
	# Pause and resume.
	for p: Array in ctl["pause"]:
		await _fresh()
		await _frames(20)
		var w := _world()
		await _hold([p[0]], [p[1]], 3)
		_expect("%s: %s pauses" % [who, p[2]], w.phase == World.PAUSED, "phase=%d" % w.phase)
		await _hold([p[0]], [p[1]], 3)
		_expect("%s: %s resumes" % [who, p[2]], w.phase == World.RUNNING, "phase=%d" % w.phase)


func _keyboard_controls() -> Dictionary:
	return {
		"throttle": [
			[_k(KEY_UP, true), _k(KEY_UP, false), "UP"],
			[_k(KEY_W, true), _k(KEY_W, false), "W"],
			[_k(KEY_Z, true), _k(KEY_Z, false), "Z"],
		],
		"nitro": [_k(KEY_X, true), _k(KEY_X, false), "X"],
		"brake": [
			[_k(KEY_DOWN, true), _k(KEY_DOWN, false), "DOWN"],
			[_k(KEY_S, true), _k(KEY_S, false), "S"],
		],
		"left": [
			[_k(KEY_LEFT, true), _k(KEY_LEFT, false), "LEFT"],
			[_k(KEY_A, true), _k(KEY_A, false), "A"],
		],
		"right": [
			[_k(KEY_RIGHT, true), _k(KEY_RIGHT, false), "RIGHT"],
			[_k(KEY_D, true), _k(KEY_D, false), "D"],
		],
		"pause": [
			[_k(KEY_ESCAPE, true), _k(KEY_ESCAPE, false), "ESC"],
			[_k(KEY_P, true), _k(KEY_P, false), "P"],
		],
	}


func _pad_controls() -> Dictionary:
	return {
		"throttle": [[_b(JOY_BUTTON_B, true), _b(JOY_BUTTON_B, false), "B"]],
		"nitro": [_b(JOY_BUTTON_A, true), _b(JOY_BUTTON_A, false), "A"],
		"brake": [[_b(JOY_BUTTON_DPAD_DOWN, true), _b(JOY_BUTTON_DPAD_DOWN, false), "DOWN"]],
		"left": [
			[_axis(JOY_AXIS_LEFT_X, -1.0), _axis(JOY_AXIS_LEFT_X, 0.0), "STICK"],
			[_b(JOY_BUTTON_DPAD_LEFT, true), _b(JOY_BUTTON_DPAD_LEFT, false), "D-PAD"],
		],
		"right": [
			[_axis(JOY_AXIS_LEFT_X, 1.0), _axis(JOY_AXIS_LEFT_X, 0.0), "STICK"],
			[_b(JOY_BUTTON_DPAD_RIGHT, true), _b(JOY_BUTTON_DPAD_RIGHT, false), "D-PAD"],
		],
		"pause": [[_b(JOY_BUTTON_START, true), _b(JOY_BUTTON_START, false), "START"]],
	}


# --- Scenarios -----------------------------------------------------------------------------------------------------


func _race_keyboard_versus() -> void:
	print("-- keyboard: join screen and versus race")
	_pad_mode = false
	app.show_title()
	app.title_choice = 0
	await _frames(3)
	tap(KEY_ENTER)
	await _frames(3)
	tap(KEY_ENTER)
	await _frames(3)
	_expect("join: ENTER seats the keyboard", app.seats.seat_of(Seats.KEYBOARD_DEVICE) >= 0)
	tap(KEY_ENTER)
	await _frames(3)
	_expect("join: ENTER again starts the race", _screen_name() == "Versus", _screen_name())
	await _race_checks(_keyboard_controls(), "keyboard/versus")


func _race_keyboard_solo() -> void:
	print("-- keyboard: single-player game")
	_pad_mode = false
	app.start_game()
	await _frames(3)
	await _race_checks(_keyboard_controls(), "keyboard/solo")


func _pad_versus() -> void:
	print("-- pad: join screen and versus race")
	_pad_mode = true
	app.show_title()
	app.title_choice = 0
	await _frames(3)
	pad_tap(PAD, JOY_BUTTON_A)
	await _frames(3)
	_expect("title: pad A starts (join screen)", _screen_name() == "Join", _screen_name())
	pad_tap(PAD, JOY_BUTTON_A)
	await _frames(3)
	_expect("join: pad A seats the pad", app.seats.seat_of(PAD) >= 0)
	pad_tap(PAD, JOY_BUTTON_START)
	await _frames(3)
	_expect("join: pad START starts the race", _screen_name() == "Versus", _screen_name())
	await _race_checks(_pad_controls(), "pad/versus")


func _pad_solo() -> void:
	print("-- pad: single-player game")
	_pad_mode = true
	app.start_game()
	await _frames(3)
	await _race_checks(_pad_controls(), "pad/solo")


# --- The other screens' hints --------------------------------------------------------------------------------------


## Waits until the solo game is over (its fuel emptied), up to WAIT_FRAMES.
func _drive_to_game_over() -> bool:
	var w := _world()
	w.players[0].fuel = 0.0
	for i in WAIT_FRAMES:
		if w.phase == World.GAME_OVER:
			return true
		await process_frame
	return false


func _panels() -> void:
	print("-- the hints on the other panels")
	# Solo game over: "ENTER / A retry", "ESC / START title".
	for pad: bool in [false, true]:
		_pad_mode = pad
		var who := "pad" if pad else "keyboard"
		app.start_game()
		await _frames(3)
		await _fresh()
		var over := await _drive_to_game_over()
		_expect("%s/solo: game over reached" % who, over)
		await _frames(70)
		var games_before: int = app.current_screen().games
		if pad:
			pad_tap(PAD, JOY_BUTTON_A)
		else:
			tap(KEY_ENTER)
		await _frames(4)
		_expect("%s/solo: game over %s retries" % [who, "A" if pad else "ENTER"],
			_screen_name() == "Game" and app.current_screen().games == games_before + 1)
		over = await _drive_to_game_over()
		await _frames(70)
		if pad:
			pad_tap(PAD, JOY_BUTTON_START)
		else:
			tap(KEY_ESCAPE)
		await _frames(4)
		_expect("%s/solo: game over %s goes to the title" % [who, "START" if pad else "ESC"], _screen_name() == "Title", _screen_name())
	# Join screen: "BACK / ESC TITLE", "B LEAVE"; the keyboard gives its seat up with Backspace.
	_pad_mode = false
	app.show_join()
	await _frames(3)
	tap(KEY_ENTER)
	await _frames(3)
	tap(KEY_BACKSPACE)
	await _frames(3)
	_expect("join: BACKSPACE gives the keyboard's seat up", app.seats.seat_of(Seats.KEYBOARD_DEVICE) < 0)
	tap(KEY_ESCAPE)
	await _frames(3)
	_expect("join: ESC goes to the title", _screen_name() == "Title", _screen_name())
	_pad_mode = true
	app.show_join()
	await _frames(3)
	pad_tap(PAD, JOY_BUTTON_A)
	await _frames(3)
	pad_tap(PAD, JOY_BUTTON_B)
	await _frames(3)
	_expect("join: pad B leaves the seat", app.seats.seat_of(PAD) < 0)
	pad_tap(PAD, JOY_BUTTON_A)
	await _frames(3)
	pad_tap(PAD, JOY_BUTTON_BACK)
	await _frames(3)
	_expect("join: pad BACK goes to the title", _screen_name() == "Title", _screen_name())
	# Versus pause panel: "START resume", "BACK / ESC quit to title".
	_pad_mode = true
	app.show_join()
	await _frames(3)
	pad_tap(PAD, JOY_BUTTON_A)
	await _frames(3)
	pad_tap(PAD, JOY_BUTTON_START)
	await _frames(3)
	await _wait_running()
	await _frames(20)
	pad_tap(PAD, JOY_BUTTON_START)
	await _frames(3)
	_expect("versus: pad START pauses", _world().phase == World.PAUSED)
	pad_tap(PAD, JOY_BUTTON_BACK)
	await _frames(3)
	_expect("versus pause panel: pad BACK quits to the title", _screen_name() == "Title", _screen_name())
	_pad_mode = false
	app.show_title()
	app.title_choice = 0
	await _frames(3)
	tap(KEY_ENTER)
	await _frames(3)
	tap(KEY_ENTER)
	await _frames(3)
	tap(KEY_ENTER)
	await _frames(3)
	await _wait_running()
	await _frames(20)
	tap(KEY_P)
	await _frames(3)
	_expect("versus: P pauses", _world().phase == World.PAUSED)
	tap(KEY_ESCAPE)
	await _frames(3)
	_expect("versus pause panel (keyboard): ESC resumes, as the panel says", _screen_name() == "Versus" and _world().phase == World.RUNNING, _screen_name())
	# Fullscreen: "F11 / ALT+ENTER".
	var f11 := InputEventKey.new()
	f11.physical_keycode = KEY_F11
	f11.pressed = true
	_expect("F11 is the fullscreen key", App.is_fullscreen_key(f11))
	var alt_enter := InputEventKey.new()
	alt_enter.physical_keycode = KEY_ENTER
	alt_enter.alt_pressed = true
	alt_enter.pressed = true
	_expect("ALT+ENTER is the fullscreen key", App.is_fullscreen_key(alt_enter))


# --- The developer dashboard ---------------------------------------------------------------------------------------


func _admin() -> void:
	print("-- admin dashboard (F1, with --admin)")
	_pad_mode = false
	app.admin_enabled = true
	app.start_game()
	await _frames(3)
	await _fresh()
	tap(KEY_F1)
	await _frames(3)
	_expect("admin: F1 opens the page", app.admin != null and app.admin.visible)
	# A slider moves the running game's rules.
	app.admin._sliders["nitro_top"].value = 250.0
	app.admin._sliders["low_gear_top"].value = 250.0
	app.admin._sliders["time_scale"].value = 2.0
	var w := _world()
	_expect("admin: the nitro top slider reaches the running game", w.cfg.nitro_top == 250.0, str(w.cfg.nitro_top))
	# The page is full-screen: the game waits behind it until F1 closes it.
	var waiting := w.stage_ticks
	await _frames(30)
	_expect("admin: the game waits while the page is open", w.stage_ticks == waiting)
	tap(KEY_F1)
	await _frames(3)
	_expect("admin: F1 closes the page", not app.admin.visible)
	var t0 := w.stage_ticks
	key(KEY_X, true)
	await _frames(500)
	var car := _car()
	key(KEY_X, false)
	_expect("admin: both gears now top out at 250", is_equal_approx(car.speed, 250.0), "speed %.1f" % car.speed)
	_expect("admin: game speed 2x runs two ticks a frame", w.stage_ticks - t0 >= 900, "%d ticks in 500 frames" % (w.stage_ticks - t0))
	# A new game keeps the values; Reset puts the shipped rules back.
	app.show_title()
	app.start_game()
	await _frames(3)
	_expect("admin: a new game keeps the values", _world().cfg.nitro_top == 250.0)
	tap(KEY_F1)
	await _frames(3)
	_expect("admin: F1 opens the page again", app.admin.visible)
	app.admin._on_reset()
	_expect("admin: Reset restores the shipped rules", _world().cfg.nitro_top == 400.0 and app.tuning.value("time_scale") == 1.0)
	tap(KEY_F1)
	await _frames(3)
	app.admin_enabled = false
