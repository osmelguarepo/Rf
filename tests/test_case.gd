extends RefCounted
## Base class of every test file. A test file is tests/test_*.gd, starts with
## `extends "res://tests/test_case.gd"` (no class_name: `-s` does not resolve them in a fresh clone) and declares
## methods named test_* that take no arguments. tests/run_tests.gd runs them (docs/GODOT_PLAN.md §6).
##
## Optional hooks: before_all() and after_all() run once per file, before_each() and after_each() around each test.
## One instance serves the whole file, so before_each() must reset any state a test leaves behind.
##
## Asserts follow GUT's names. Each failure records the file:line of the assert call in the test file. A test fails
## if an assert fails, if anything logs an error (push_error, a script error, an engine error) while it runs, or if
## it makes no assert at all. Tests are synchronous: a test file that uses `await` is rejected.

const SELF_PATH := "res://tests/test_case.gd"
## Longest text shown for one value in a failure message.
const SHOW_LIMIT := 400

## Asserts made and failures recorded by the current test. The runner reads and resets them.
var _asserts: int = 0
var _failures: PackedStringArray = []


## Called by the runner before each test.
func _begin_test() -> void:
	_asserts = 0
	_failures = PackedStringArray()


## Equal, with strict types: an int never equals a float, and arrays and dictionaries are compared element by
## element with the same rule. Floats are compared with ==, so this is bit-exact apart from 0.0 == -0.0.
func assert_eq(got: Variant, expected: Variant, text: String = "") -> void:
	_asserts += 1
	if not strict_equal(got, expected):
		_fail("assert_eq: expected %s, got %s" % [show(expected), show(got)], text)


## Not equal, with the same strict comparison as assert_eq (values of different types are never equal).
func assert_ne(got: Variant, not_expected: Variant, text: String = "") -> void:
	_asserts += 1
	if strict_equal(got, not_expected):
		_fail("assert_ne: did not expect %s" % show(got), text)


## |got - expected| <= tolerance. Both values must be numbers (int or float).
func assert_almost_eq(got: Variant, expected: Variant, tolerance: float, text: String = "") -> void:
	_asserts += 1
	if not (_is_number(got) and _is_number(expected)):
		_fail("assert_almost_eq: needs numbers, got %s and %s" % [show(got), show(expected)], text)
	elif not (absf(float(got) - float(expected)) <= tolerance):
		_fail("assert_almost_eq: expected %s within %s, got %s (off by %s)" % [
			show(expected), show(tolerance), show(got), show(absf(float(got) - float(expected)))
		], text)


func assert_true(got: Variant, text: String = "") -> void:
	_asserts += 1
	if typeof(got) != TYPE_BOOL:
		_fail("assert_true: expected a bool, got %s" % show(got), text)
	elif not got:
		_fail("assert_true: got false", text)


func assert_false(got: Variant, text: String = "") -> void:
	_asserts += 1
	if typeof(got) != TYPE_BOOL:
		_fail("assert_false: expected a bool, got %s" % show(got), text)
	elif got:
		_fail("assert_false: got true", text)


## got > bound. Both must be numbers.
func assert_gt(got: Variant, bound: Variant, text: String = "") -> void:
	_asserts += 1
	if not (_is_number(got) and _is_number(bound)):
		_fail("assert_gt: needs numbers, got %s and %s" % [show(got), show(bound)], text)
	elif not (got > bound):
		_fail("assert_gt: expected more than %s, got %s" % [show(bound), show(got)], text)


## got < bound. Both must be numbers.
func assert_lt(got: Variant, bound: Variant, text: String = "") -> void:
	_asserts += 1
	if not (_is_number(got) and _is_number(bound)):
		_fail("assert_lt: needs numbers, got %s and %s" % [show(got), show(bound)], text)
	elif not (got < bound):
		_fail("assert_lt: expected less than %s, got %s" % [show(bound), show(got)], text)


## low <= got <= high. All three must be numbers.
func assert_between(got: Variant, low: Variant, high: Variant, text: String = "") -> void:
	_asserts += 1
	if not (_is_number(got) and _is_number(low) and _is_number(high)):
		_fail("assert_between: needs numbers, got %s, %s and %s" % [show(got), show(low), show(high)], text)
	elif not (got >= low and got <= high):
		_fail("assert_between: expected %s to %s, got %s" % [show(low), show(high), show(got)], text)


func assert_null(got: Variant, text: String = "") -> void:
	_asserts += 1
	if got != null:
		_fail("assert_null: got %s" % show(got), text)


func assert_not_null(got: Variant, text: String = "") -> void:
	_asserts += 1
	if got == null:
		_fail("assert_not_null: got null", text)


## The container (Array, packed array, Dictionary key or String) holds the value.
func assert_has(container: Variant, value: Variant, text: String = "") -> void:
	_asserts += 1
	if not _contains(container, value):
		_fail("assert_has: %s not in %s" % [show(value), show(container)], text)


func assert_does_not_have(container: Variant, value: Variant, text: String = "") -> void:
	_asserts += 1
	if _contains(container, value):
		_fail("assert_does_not_have: %s is in %s" % [show(value), show(container)], text)


## Fails the test with a message. Counts as an assert.
func fail_test(text: String) -> void:
	_asserts += 1
	_fail("fail_test", text)


## Marks a check that has no assert of its own as made. Counts as an assert.
func pass_test(_text: String = "") -> void:
	_asserts += 1


## Same type and same value; arrays and dictionaries element by element.
static func strict_equal(a: Variant, b: Variant) -> bool:
	if typeof(a) != typeof(b):
		return false
	if a is Array:
		var x: Array = a
		var y: Array = b
		if x.size() != y.size():
			return false
		for i in x.size():
			if not strict_equal(x[i], y[i]):
				return false
		return true
	if a is Dictionary:
		var x: Dictionary = a
		var y: Dictionary = b
		if x.size() != y.size():
			return false
		for key: Variant in x:
			if not y.has(key) or not strict_equal(x[key], y[key]):
				return false
		return true
	return a == b


## The 8 bytes of a double, little-endian, as 16 hex digits: the encoding of tests/golden/phaser_golden.json.
static func hex_of(value: float) -> String:
	var bytes := PackedByteArray()
	bytes.resize(8)
	bytes.encode_double(0, value)
	return bytes.hex_encode()


## The double behind 16 hex digits written by hex_of().
static func double_of(hex: String) -> float:
	return hex.hex_decode().decode_double(0)


## A value for a failure message. Floats also show their bits, so values that print alike can be told apart.
static func show(value: Variant) -> String:
	var text := ""
	if typeof(value) == TYPE_FLOAT:
		text = "%s [%s]" % [var_to_str(value), hex_of(value)]
	elif typeof(value) == TYPE_STRING:
		text = '"%s"' % value
	else:
		text = var_to_str(value).replace("\n", " ")
	if text.length() > SHOW_LIMIT:
		text = text.substr(0, SHOW_LIMIT) + "..."
	return text


static func _is_number(value: Variant) -> bool:
	return typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT


static func _contains(container: Variant, value: Variant) -> bool:
	if container is Dictionary:
		return (container as Dictionary).has(value)
	if typeof(container) == TYPE_STRING:
		return typeof(value) == TYPE_STRING and (container as String).contains(value)
	if container is Array:
		for item: Variant in container:
			if strict_equal(item, value):
				return true
		return false
	if typeof(container) >= TYPE_PACKED_BYTE_ARRAY and typeof(container) <= TYPE_PACKED_VECTOR4_ARRAY:
		return container.has(value)
	return false


func _fail(message: String, text: String) -> void:
	var line := "%s: %s" % [_caller(), message]
	if not text.is_empty():
		line += " (%s)" % text
	_failures.append(line)


## file:line of the first script frame outside this file: the assert call in the test.
func _caller() -> String:
	for backtrace: ScriptBacktrace in Engine.capture_script_backtraces():
		for i in backtrace.get_frame_count():
			var file := backtrace.get_frame_file(i)
			if file != SELF_PATH:
				return "%s:%d" % [file.trim_prefix("res://"), backtrace.get_frame_line(i)]
	return "unknown location"
