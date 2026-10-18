extends SceneTree
## The test runner (docs/GODOT_PLAN.md §6). tools/test.sh runs it; it also runs on its own:
##
##   godot --headless --path . -s res://tests/run_tests.gd [-- [--only=PATTERN[,PATTERN...]] [--no-steam]]
##
## It finds tests/test_*.gd (every one but test_case.gd, the base class) and their test_* methods, both sorted by
## name, and runs them synchronously inside _initialize(). --only= keeps the tests whose id,
## "tests/test_x.gd::test_y", contains one of the patterns; it may be given more than once. --no-steam (B4) keeps
## the real Steam out of the run on a PC where it runs: scripts/input/steam_input.gd reads it from the command line,
## and the one test that starts the real GodotSteam then checks that --no-steam starts nothing (docs/STEAM_INPUT.md).
##
## Each test prints "PASS <id>" or "FAIL <id>" followed by the reasons. The last line is "N passed, M failed".
## A test fails when an assert fails, when any error is logged while it runs (ErrorCounter below, registered with
## OS.add_logger(); warnings do not count) or when it makes no assert. A file fails, and counts as one failure, when
## it does not compile (not can_instantiate()), does not extend tests/test_case.gd, uses await, or has no tests.
##
## Exit code: 0 when every test passed and at least one ran; 1 when anything failed or no test ran; 70 when the run
## did not reach its end (quit(70) is requested first, so a script error that aborts the runner still fails).

const TEST_DIR := "res://tests"
const BASE_PATH := "res://tests/test_case.gd"
const EXIT_ABORTED := 70
const ONLY_PREFIX := "--only="
## Read by scripts/input/steam_input.gd (B4), not by the runner.
const NO_STEAM := "--no-steam"


## Collects every error logged by the engine or by scripts, so the runner can pin it on the test that ran.
class ErrorCounter extends Logger:
	var _mutex := Mutex.new()
	var _errors := PackedStringArray()

	func _log_error(
		function: String,
		file: String,
		line: int,
		code: String,
		rationale: String,
		_editor_notify: bool,
		error_type: int,
		script_backtraces: Array[ScriptBacktrace]
	) -> void:
		if error_type == ERROR_TYPE_WARNING:
			return
		var message := rationale if not rationale.is_empty() else code
		var where := "%s:%d (%s)" % [file, line, function]
		for backtrace: ScriptBacktrace in script_backtraces:
			if backtrace.get_frame_count() > 0:
				where = "%s:%d" % [backtrace.get_frame_file(0).trim_prefix("res://"), backtrace.get_frame_line(0)]
				break
		var kind := "script error" if error_type == ERROR_TYPE_SCRIPT else "error"
		_mutex.lock()
		_errors.append("%s: %s: %s" % [where, kind, message])
		_mutex.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass

	## The errors logged since the last call, oldest first.
	func take() -> PackedStringArray:
		_mutex.lock()
		var errors := _errors
		_errors = PackedStringArray()
		_mutex.unlock()
		return errors


var _counter := ErrorCounter.new()
var _patterns := PackedStringArray()
var _passed := 0
var _failed := 0
## Id of the test being run, until its result is recorded. Set if a script error aborted _run_file().
var _pending_id := ""
var _finished := false


func _initialize() -> void:
	quit(EXIT_ABORTED)
	OS.add_logger(_counter)
	_run()
	OS.remove_logger(_counter)
	if _finished:
		quit(1 if _failed > 0 or _passed == 0 else 0)


func _run() -> void:
	var started := Time.get_ticks_msec()
	if not _read_arguments():
		print("")
		print("%d passed, %d failed" % [_passed, _failed])
		_finished = true
		return
	var unattributed := _counter.take()
	if not unattributed.is_empty():
		_record("runner start-up", false, unattributed, 0, 0)
	for path in _test_files():
		_run_file(path)
		if not _pending_id.is_empty():
			var reasons := PackedStringArray(["the test stopped the runner's loop over its file"])
			reasons.append_array(_counter.take())
			_record(_pending_id, false, reasons, 0, 0)
			_pending_id = ""
	if _passed == 0 and _failed == 0:
		print("no test matched %s" % ", ".join(_patterns) if not _patterns.is_empty() else "no tests found")
	print("")
	print("ran in %.1f s" % ((Time.get_ticks_msec() - started) / 1000.0))
	print("%d passed, %d failed" % [_passed, _failed])
	_finished = true


## Reads --only= patterns and lets --no-steam through (the Steam Input adapter reads it). Any other argument is a
## mistake and fails the run.
func _read_arguments() -> bool:
	var ok := true
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with(ONLY_PREFIX):
			for pattern in argument.trim_prefix(ONLY_PREFIX).split(",", false):
				_patterns.append(pattern.strip_edges())
		elif argument != NO_STEAM:
			_record("arguments", false, PackedStringArray([
				"unknown argument %s (only --only=PATTERN and %s)" % [argument, NO_STEAM]
			]), 0, 0)
			ok = false
	return ok


func _test_files() -> PackedStringArray:
	var files := PackedStringArray()
	for name in DirAccess.get_files_at(TEST_DIR):
		if name.begins_with("test_") and name.ends_with(".gd") and TEST_DIR + "/" + name != BASE_PATH:
			files.append(TEST_DIR + "/" + name)
	files.sort()
	return files


func _selected(id: String) -> bool:
	if _patterns.is_empty():
		return true
	for pattern in _patterns:
		if id.contains(pattern):
			return true
	return false


func _run_file(path: String) -> void:
	var file_id := path.trim_prefix("res://")
	var stray := _counter.take()
	if not stray.is_empty():
		_record("errors logged between files", false, stray, 0, 0)

	var script := ResourceLoader.load(path) as GDScript
	var problems := _counter.take()
	if script == null or not script.can_instantiate():
		problems.insert(0, "does not compile")
	elif not _extends_base(script):
		problems.insert(0, "does not extend %s" % BASE_PATH)
	elif _uses_await(script.source_code):
		problems.insert(0, "uses await; tests must be synchronous")

	var tests := PackedStringArray()
	var bad_methods := PackedStringArray()
	if problems.is_empty():
		for method: Dictionary in script.get_script_method_list():
			var name: String = method["name"]
			if not name.begins_with("test_") or tests.has(name) or bad_methods.has(name):
				continue
			if (int(method["flags"]) & METHOD_FLAG_STATIC) != 0 or not (method["args"] as Array).is_empty():
				bad_methods.append(name)
			else:
				tests.append(name)
		tests.sort()
		if tests.is_empty() and bad_methods.is_empty():
			problems.append("has no test_* methods")
	if not problems.is_empty():
		if _selected(file_id):
			_record(file_id, false, problems, 0, 0)
		return

	for name in bad_methods:
		if _selected("%s::%s" % [file_id, name]):
			_record("%s::%s" % [file_id, name], false, PackedStringArray(["a test must not be static or take arguments"]), 0, 0)
	var selected := PackedStringArray()
	for name in tests:
		if _selected("%s::%s" % [file_id, name]):
			selected.append(name)
	if selected.is_empty():
		return

	var instance: Object = script.new()
	if instance != null and instance.has_method("before_all"):
		_call(instance, "before_all")
	var setup_errors := _counter.take()
	if instance == null or not setup_errors.is_empty():
		setup_errors.insert(0, "could not be set up (new() or before_all())")
		_record(file_id, false, setup_errors, 0, 0)
		return

	for name in selected:
		var id := "%s::%s" % [file_id, name]
		_pending_id = id
		var started := Time.get_ticks_usec()
		instance.call("_begin_test")
		if instance.has_method("before_each"):
			_call(instance, "before_each")
		_call(instance, name)
		if instance.has_method("after_each"):
			_call(instance, "after_each")
		var elapsed_ms := int((Time.get_ticks_usec() - started) / 1000.0)
		var reasons := PackedStringArray()
		reasons.append_array(instance.get("_failures"))
		reasons.append_array(_counter.take())
		var asserts: int = instance.get("_asserts")
		if reasons.is_empty() and asserts == 0:
			reasons.append("made no assert")
		_record(id, reasons.is_empty(), reasons, asserts, elapsed_ms)
		_pending_id = ""

	if instance.has_method("after_all"):
		_call(instance, "after_all")
		var teardown_errors := _counter.take()
		if not teardown_errors.is_empty():
			teardown_errors.insert(0, "after_all() logged errors")
			_record(file_id, false, teardown_errors, 0, 0)


## Calls one method as a statement, so a script error at the call aborts only this function.
func _call(instance: Object, method: String) -> void:
	instance.call(method)


func _record(id: String, passed: bool, reasons: PackedStringArray, asserts: int, elapsed_ms: int) -> void:
	if passed:
		_passed += 1
		print("PASS %s (%d asserts, %d ms)" % [id, asserts, elapsed_ms])
		return
	_failed += 1
	print("FAIL %s" % id)
	for reason in reasons:
		print("    " + reason)


func _extends_base(script: Script) -> bool:
	var base := script.get_base_script()
	while base != null:
		if base.resource_path == BASE_PATH:
			return true
		base = base.get_base_script()
	return false


## True if the code has the await keyword outside comments and string literals.
func _uses_await(source: String) -> bool:
	var keyword := RegEx.create_from_string("\\bawait\\b")
	for line in source.split("\n"):
		if keyword.search(_code_only(line)) != null:
			return true
	return false


## A line without its comment and with its string literals emptied.
static func _code_only(line: String) -> String:
	var out := ""
	var quote := ""
	var i := 0
	while i < line.length():
		var ch := line[i]
		if quote.is_empty():
			if ch == "#":
				break
			if ch == "\"" or ch == "'":
				quote = ch
			out += ch
		elif ch == "\\":
			i += 1
		elif ch == quote:
			quote = ""
			out += ch
		i += 1
	return out
