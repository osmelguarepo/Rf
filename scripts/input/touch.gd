extends RefCounted
## Touch controls: on-screen buttons that press the keyboard's keys. A touch on a button sends the key down, the end of the
## touch sends it up, so the whole game (single player, the join screen, versus, the menus) works as it does with a keyboard
## and nothing else needs to know about fingers. App turns each (key, pressed) into an InputEventKey.
##
## - Whether the controls show depends on the device: `active` starts true on a device with a touch screen (detect()), a
##   real touch turns it on, and a real key or joypad event turns it off (a laptop with a touch screen and a keyboard).
##   The key events this class made never count as a keyboard: each is remembered (`_own`) until it comes back to handle_event().
## - What shows depends on the screen (`mode`): MODE_RACE in a race (steer left and right, gas, brake, nitro, pause, and OK and
##   BACK for the panels), MODE_MENU on the menu screens (a D-pad, OK, BACK, delete, fullscreen and the volume), MODE_NONE
##   otherwise. The layout is in the 640x360 view's pixels.
## - Several fingers at once: each touch holds the button it began on, and follows it when it slides to another.

const ViewConfig := preload("res://scripts/view/view_config.gd")


const MODE_NONE := 0
const MODE_RACE := 1
const MODE_MENU := 2

## A touch counts as on a button this many pixels beyond its edge, and the nearest button wins.
const SLOP := 10.0

## Button ids.
const LEFT := &"left"
const RIGHT := &"right"
const GAS := &"gas"
const BRAKE := &"brake"
const NITRO := &"nitro"
const PAUSE := &"pause"
const OK := &"ok"
const BACK := &"back"
const UP := &"up"
const DOWN := &"down"
const DELETE := &"delete"
const FULLSCREEN := &"fullscreen"
const MUTE := &"mute"
const VOLUME_DOWN := &"volume_down"
const VOLUME_UP := &"volume_up"

## The buttons of a mode: id, shape (a circle: centre and radius; a rect), the key it presses and its label.
const RACE_BUTTONS: Array[Dictionary] = [
	{"id": LEFT, "centre": Vector2(40, 318), "radius": 32.0, "key": KEY_LEFT, "label": "<"},
	{"id": RIGHT, "centre": Vector2(108, 318), "radius": 32.0, "key": KEY_RIGHT, "label": ">"},
	{"id": NITRO, "centre": Vector2(600, 310), "radius": 34.0, "key": KEY_X, "label": "NOS"},
	{"id": GAS, "centre": Vector2(532, 322), "radius": 28.0, "key": KEY_UP, "label": "GAS"},
	{"id": BRAKE, "centre": Vector2(560, 248), "radius": 26.0, "key": KEY_DOWN, "label": "BRK"},
	{"id": PAUSE, "rect": Rect2(252, 4, 44, 28), "key": KEY_P, "label": "II"},
	{"id": OK, "rect": Rect2(298, 4, 44, 28), "key": KEY_ENTER, "label": "OK"},
	{"id": BACK, "rect": Rect2(344, 4, 44, 28), "key": KEY_ESCAPE, "label": "ESC"},
]
const MENU_BUTTONS: Array[Dictionary] = [
	{"id": UP, "centre": Vector2(72, 256), "radius": 22.0, "key": KEY_UP, "label": "^"},
	{"id": DOWN, "centre": Vector2(72, 336), "radius": 22.0, "key": KEY_DOWN, "label": "v"},
	{"id": LEFT, "centre": Vector2(30, 296), "radius": 22.0, "key": KEY_LEFT, "label": "<"},
	{"id": RIGHT, "centre": Vector2(114, 296), "radius": 22.0, "key": KEY_RIGHT, "label": ">"},
	{"id": OK, "centre": Vector2(592, 304), "radius": 34.0, "key": KEY_ENTER, "label": "OK"},
	{"id": BACK, "centre": Vector2(524, 322), "radius": 26.0, "key": KEY_ESCAPE, "label": "ESC"},
	{"id": DELETE, "centre": Vector2(596, 236), "radius": 22.0, "key": KEY_BACKSPACE, "label": "DEL"},
	{"id": FULLSCREEN, "rect": Rect2(4, 4, 30, 26), "key": KEY_F11, "label": "[ ]"},
	{"id": MUTE, "rect": Rect2(36, 4, 30, 26), "key": KEY_M, "label": "SND"},
	{"id": VOLUME_DOWN, "rect": Rect2(68, 4, 30, 26), "key": KEY_MINUS, "label": "-"},
	{"id": VOLUME_UP, "rect": Rect2(100, 4, 30, 26), "key": KEY_EQUAL, "label": "+"},
]

## True while the controls show (see the class comment). App.touch_active() adds the conditions of the page.
var active: bool = false
var mode: int = MODE_NONE
## Called with (keycode: int, pressed: bool) for each key a button presses or lets go.
var emit_key: Callable = Callable()
## Touch index -> the id of the button it holds ("" for none).
var _touch_button: Dictionary = {}
## Button id -> how many touches hold it.
var _holds: Dictionary = {}
## Key events made and not seen back yet: (keycode * 2 + pressed) -> how many.
var _own: Dictionary = {}


## True on a device whose main pointer is a finger: the page says so (WebBridge.coarse_pointer()) or the build is a phone's.
## A touch screen next to a keyboard (a laptop, a Steam Deck) starts without the controls; its first touch shows them.
static func detect(page_says_touch: bool = false) -> bool:
	return page_says_touch or OS.has_feature("mobile")


## The buttons shown in a mode.
static func buttons_of(p_mode: int) -> Array[Dictionary]:
	if p_mode == MODE_RACE:
		return RACE_BUTTONS
	if p_mode == MODE_MENU:
		return MENU_BUTTONS
	return []


func buttons() -> Array[Dictionary]:
	return buttons_of(mode) if active else ([] as Array[Dictionary])


## True while a button is held down.
func is_held(id: StringName) -> bool:
	return _holds.get(id, 0) > 0


## Changes what shows. Every button let go first (a finger on a button that goes away would hold its key for good).
func set_mode(p_mode: int) -> void:
	if p_mode != mode:
		release_all()
		mode = p_mode


## Turns the controls on or off. Off lets everything go.
func set_active(on: bool) -> void:
	if on != active:
		active = on
		if not on:
			release_all()


## Lets go of every key a button holds and forgets the touches.
func release_all() -> void:
	for id: StringName in _holds.keys():
		_emit(id, false)
	_holds = {}
	_touch_button = {}


## Follows an input event. Returns true if it was a touch that began on a button or moved a touch that holds one (the app
## keeps such an event from the screens), so a tap on the title's own buttons still reaches the title.
func handle_event(event: InputEvent) -> bool:
	var touch := event as InputEventScreenTouch
	if touch != null:
		set_active(true)
		if touch.pressed:
			return _press(touch.index, touch.position)
		return _release(touch.index)
	var drag := event as InputEventScreenDrag
	if drag != null:
		return _move(drag.index, drag.position)
	var key := event as InputEventKey
	if key != null:
		if not _is_own(key) and key.pressed:
			set_active(false)
	elif event is InputEventJoypadButton and (event as InputEventJoypadButton).pressed:
		set_active(false)
	return false


## The button under a point (nearest by distance beyond its edge), or &"" for none.
func button_at(point: Vector2) -> StringName:
	var best: StringName = &""
	var best_gap := SLOP
	for button: Dictionary in buttons():
		var gap := _gap(button, point)
		if gap <= best_gap:
			best_gap = gap
			best = button["id"]
	return best


func _press(index: int, point: Vector2) -> bool:
	var id := button_at(point)
	_touch_button[index] = id
	if id == &"":
		return false
	_hold(id)
	return true


func _move(index: int, point: Vector2) -> bool:
	if not _touch_button.has(index):
		return false
	var was: StringName = _touch_button[index]
	var now := button_at(point)
	if now != was:
		if was != &"":
			_let_go(was)
		_touch_button[index] = now
		if now != &"":
			_hold(now)
	return was != &"" or now != &""


func _release(index: int) -> bool:
	if not _touch_button.has(index):
		return false
	var id: StringName = _touch_button[index]
	_touch_button.erase(index)
	if id != &"":
		_let_go(id)
	return id != &""


func _hold(id: StringName) -> void:
	var count: int = _holds.get(id, 0)
	_holds[id] = count + 1
	if count == 0:
		_emit(id, true)


func _let_go(id: StringName) -> void:
	var count: int = _holds.get(id, 0)
	if count <= 1:
		_holds.erase(id)
		if count == 1:
			_emit(id, false)
	else:
		_holds[id] = count - 1


func _emit(id: StringName, pressed: bool) -> void:
	if not emit_key.is_valid():
		return
	for button: Dictionary in RACE_BUTTONS + MENU_BUTTONS:
		if button["id"] == id:
			var tag: int = int(button["key"]) * 2 + (1 if pressed else 0)
			_own[tag] = int(_own.get(tag, 0)) + 1
			emit_key.call(button["key"], pressed)
			return


## How far a point is beyond a button's edge (0 or less inside).
static func _gap(button: Dictionary, point: Vector2) -> float:
	if button.has("rect"):
		var rect: Rect2 = button["rect"]
		var dx := maxf(maxf(rect.position.x - point.x, point.x - rect.end.x), 0.0)
		var dy := maxf(maxf(rect.position.y - point.y, point.y - rect.end.y), 0.0)
		return Vector2(dx, dy).length()
	var centre: Vector2 = button["centre"]
	return centre.distance_to(point) - float(button["radius"])


## True, once, for a key event this class made.
func _is_own(key: InputEventKey) -> bool:
	var code := key.physical_keycode if key.physical_keycode != KEY_NONE else key.keycode
	var tag := int(code) * 2 + (1 if key.pressed else 0)
	var count: int = _own.get(tag, 0)
	if count == 0:
		return false
	if count == 1:
		_own.erase(tag)
	else:
		_own[tag] = count - 1
	return true
