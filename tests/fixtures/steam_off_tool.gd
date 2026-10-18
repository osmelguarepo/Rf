extends "res://tools/tool_base.gd"
## A tool for tests/test_steam_input.gd (B4), run with -s in a child Godot: it boots the game with tool_base.gd's
## start_app(), as tools/smoke.gd, screenshots.gd and scalecheck.gd do, and on its second frame, after the app's
## _ready() (which starts Steam Input unless it is off), prints the state of the app's Steam Input adapter and ends
## with finish(0, "steam_off_tool: PASS").


func _initialize() -> void:
	if not begin():
		finish(1)
		return
	start_app(1)


func _process(_delta: float) -> bool:
	if _finished:
		return false
	frame += 1
	if frame == 2:
		print("steam_off_tool: steam %s, no_steam %s" % [app.steam.state_name(), app.no_steam])
		finish(0, "steam_off_tool: PASS")
	return false
