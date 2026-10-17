extends "res://tests/test_case.gd"
## The verdict line of the tools (tools/tool_base.gd): finish(0, pass_line) prints the line only once the run has
## really passed, at the very end. _finalize() runs only when a tool's own process shuts down, so each test runs
## tests/fixtures/pass_line_tool.gd in a child Godot and reads its output and exit code.

const FIXTURE := "res://tests/fixtures/pass_line_tool.gd"
const PASS_LINE := "pass_line_tool: PASS"
const FAIL_LINE := "pass_line_tool: FAIL: errors logged at the end of the run"


## Runs the fixture with the given user arguments; returns [exit code, output lines].
func _run_fixture(user_args: PackedStringArray) -> Array:
	var args := PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"), "-s", FIXTURE, "--"
	])
	args.append_array(user_args)
	var output: Array = []
	var code := OS.execute(OS.get_executable_path(), args, output, true)
	var lines := PackedStringArray()
	for chunk: String in output:
		for line in chunk.split("\n"):
			lines.append(line.strip_edges())
	return [code, lines]


func test_pass_line_printed_when_the_run_passes() -> void:
	var result := _run_fixture(PackedStringArray())
	var lines: PackedStringArray = result[1]
	assert_eq(result[0], 0, "exit code; output: %s" % "\n".join(lines))
	assert_true(lines.has(PASS_LINE), "the pass line")
	assert_false(lines.has(FAIL_LINE), "no fail line")


func test_late_error_fails_without_the_pass_line() -> void:
	var result := _run_fixture(PackedStringArray(["--late-error=1"]))
	var lines: PackedStringArray = result[1]
	assert_eq(result[0], 1, "exit code; output: %s" % "\n".join(lines))
	assert_false(lines.has(PASS_LINE), "no pass line after a late error")
	assert_true(lines.has(FAIL_LINE), "the fail line")
