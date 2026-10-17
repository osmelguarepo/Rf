extends "res://tools/tool_base.gd"
## A tool for tests/test_tools.gd, run with -s in a child Godot. On its first frame it ends with
## finish(0, "pass_line_tool: PASS"); with --late-error=1 after "--" it then logs an error in the same frame, which
## _finalize() must turn into a failure that never prints the pass line.


func _initialize() -> void:
	if not begin():
		finish(1)


func _process(_delta: float) -> bool:
	if _finished:
		return false
	finish(0, "pass_line_tool: PASS")
	if user_arg("late-error", "0") == "1":
		push_error("pass_line_tool: a late error")
	return false
