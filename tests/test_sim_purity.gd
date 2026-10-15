extends "res://tests/test_case.gd"
## docs/GODOT_PLAN.md §3: scripts/sim is pure and deterministic. This test reads the source of every file there,
## without comments and string literals, and fails on anything from the forbidden list:
##
## - class_name (a fresh clone run with -s does not resolve it), static var, autoloads, nodes and engine
##   singletons (clock, input, files, project settings, engine RNG);
## - Vector2/3/4, Rect2 and PackedFloat32Array (32-bit floats), **, pow, lerp, sin, cos, tan, exp, log, hash,
##   randomize, randf, randi;
## - number literals with 10 or more decimals;
## - fields other than int, float and the simulation's own classes (no bool, String, Dictionary or Variant);
## - preloads from outside scripts/sim, and anything that does not extend RefCounted.

const SIM_DIR := "res://scripts/sim"
const SIM_PREFIX := "res://scripts/sim/"

## Rule name and regular expression, matched against code with comments and strings removed.
const FORBIDDEN := [
	["class_name", "\\bclass_name\\b"],
	["static var", "\\bstatic\\s+var\\b"],
	["32-bit vector or rect", "\\b(Vector[234]i?|Rect2i?|Transform2D|Color)\\b"],
	["PackedFloat32Array", "\\bPackedFloat32Array\\b"],
	["** (power)", "\\*\\*"],
	["pow", "\\bpow[fi]?\\s*\\("],
	["lerp", "\\b(lerp|lerpf|lerp_angle|inverse_lerp|smoothstep|move_toward)\\s*\\("],
	["trigonometry", "\\b(sin|cos|tan|sinh|cosh|tanh|asin|acos|atan|atan2|deg_to_rad|rad_to_deg)\\s*\\("],
	["exp or log", "\\b(exp|log)\\s*\\("],
	["hash", "\\bhash\\s*\\("],
	["global RNG", "\\b(randomize|randf|randi|randf_range|randi_range|randfn|rand_from_seed|seed)\\s*\\("],
	["engine RNG", "\\bRandomNumberGenerator\\b"],
	["node or scene tree", "\\b(Node|Node2D|Node3D|CanvasItem|Control|SceneTree|get_tree|get_node|add_child)\\b"],
	[
		"engine singleton",
		"\\b(Engine|OS|Time|Input|InputMap|DisplayServer|RenderingServer|ProjectSettings|Performance|ResourceLoader|FileAccess|DirAccess|JavaScriptBridge|ClassDB|AudioServer)\\b"
	],
	["load() at run time", "(^|[^\\w])load\\s*\\("],
	["await", "\\bawait\\b"],
	["literal with 10+ decimals", "\\b\\d+\\.\\d{10,}"],
]
## Types a field may have: numbers, and the simulation's own classes and arrays of them.
const FIELD_TYPE := "^(int|float|Config|Rng|Car|Traffic|Spawner|Traffic\\.Spawner|Self|Array\\[(int|float|Car|Traffic)\\])$"


func test_sim_purity() -> void:
	var files := _sim_files()
	assert_gt(files.size(), 7, "simulation files scanned")
	var problems: Array = []
	for path in files:
		problems.append_array(scan(path.trim_prefix("res://"), FileAccess.get_file_as_string(path)))
	assert_eq(problems, [], "forbidden in scripts/sim")


## The scanner itself: it must catch each rule in code and ignore the same words in comments and strings.
func test_purity_scanner_catches_and_ignores() -> void:
	var bad := "\n".join([
		"extends Node",
		"class_name Foo",
		"static var cache := 0",
		"var position: Vector2",
		"var flag: bool = false",
		"var x := 2.0 ** 3",
		"var y := pow(2.0, 3.0) + lerp(1.0, 2.0, 0.5) + sin(1.0) + exp(1.0) + log(2.0)",
		"var t := Time.get_ticks_msec() + randi() + hash(3)",
		"var r := RandomNumberGenerator.new()",
		"const P := preload(\"res://scripts/view/road.gd\")",
		"var third := 0.3333333333",
		"var s := load(\"res://x.gd\")",
	])
	var rules := {}
	for problem: String in scan("bad.gd", bad):
		rules[problem.get_slice(": ", 1)] = true
	for rule: String in [
		"extends RefCounted", "class_name", "static var", "32-bit vector or rect", "field type", "** (power)", "pow",
		"lerp", "trigonometry", "exp or log", "engine singleton", "global RNG", "hash", "engine RNG",
		"preload outside scripts/sim", "literal with 10+ decimals", "load() at run time",
	]:
		assert_true(rules.has(rule), "caught: %s" % rule)
	var clean := "\n".join([
		"extends RefCounted",
		"## Never Vector2 or Rect2 or class_name here; pow() and Time.now are fine in comments.",
		"const NAMES := [\"Node\", \"sin(\", \"static var\", \"# not a comment\"]",
		"const Car := preload(\"res://scripts/sim/car.gd\")",
		"var speed: float = 0.0  # Vector2 in a trailing comment",
		"var seats: Array[Car] = []",
		"var game_seed: int = 0",
		"func f() -> void:",
		"\tvar local := \"Engine\"",
		"\tvar ok: bool = true",
	])
	assert_eq(scan("clean.gd", clean), [], "comments, strings and local variables are not flagged")


static func _sim_files() -> PackedStringArray:
	var out := PackedStringArray()
	for name in DirAccess.get_files_at(SIM_DIR):
		if name.ends_with(".gd"):
			out.append(SIM_DIR + "/" + name)
	out.sort()
	return out


## Every rule broken in one file, as "file:line: rule: code".
static func scan(file: String, source: String) -> Array:
	var problems: Array = []
	var patterns: Array = []
	for rule: Array in FORBIDDEN:
		patterns.append([rule[0], RegEx.create_from_string(rule[1])])
	var field_type := RegEx.create_from_string(FIELD_TYPE)
	var member := RegEx.create_from_string("^var\\s+(\\w+)\\s*(:\\s*([^=]+?))?\\s*(:?=|$)")
	var preload_path := RegEx.create_from_string("preload\\(\"([^\"]*)\"\\)")
	var lines := source.split("\n")
	var first_code := ""
	var in_class := false
	for index in lines.size():
		var raw := lines[index]
		var code := strip_comments_and_strings(raw)
		var where := "%s:%d" % [file, index + 1]
		if code.strip_edges().is_empty():
			continue
		if first_code.is_empty():
			first_code = code.strip_edges()
		for pattern: Array in patterns:
			if (pattern[1] as RegEx).search(code) != null:
				problems.append("%s: %s: %s" % [where, pattern[0], raw.strip_edges()])
		for found: RegExMatch in preload_path.search_all(raw):
			if not found.get_string(1).begins_with(SIM_PREFIX):
				problems.append("%s: preload outside scripts/sim: %s" % [where, raw.strip_edges()])
		# Fields: `var` at the top level, or one tab in inside an inner class.
		var indent := raw.length() - raw.lstrip("\t").length()
		if indent == 0:
			in_class = code.begins_with("class ")
		var declaration := ""
		if indent == 0 and code.begins_with("var "):
			declaration = code
		elif indent == 1 and in_class and code.strip_edges().begins_with("var "):
			declaration = code.strip_edges()
		if not declaration.is_empty():
			var found := member.search(declaration)
			var type_name := "" if found == null else found.get_string(3).strip_edges()
			if field_type.search(type_name) == null:
				problems.append("%s: field type: %s" % [where, raw.strip_edges()])
	if first_code != "extends RefCounted":
		problems.append("%s:1: extends RefCounted: %s" % [file, first_code])
	return problems


## The code part of a line: string literals emptied and the comment cut off.
static func strip_comments_and_strings(line: String) -> String:
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
		else:
			if ch == "\\":
				i += 1
			elif ch == quote:
				quote = ""
				out += ch
		i += 1
	return out
