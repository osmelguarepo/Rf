extends "res://tests/test_case.gd"
## tests/PARITY.md maps the 60 rule tests of the Phaser version (docs/GODOT_PLAN.md §6) to GDScript tests. This
## checks the table: one row per Phaser test (car 20, fuel 6, loop 7, state 16, traffic 11), and each row either
## names test methods that exist or says "dropped:" with a reason.

const PARITY := "res://tests/PARITY.md"
const EXPECTED_COUNTS := {"car": 20, "fuel": 6, "loop": 7, "state": 16, "traffic": 11}


func test_parity_maps_all_60_phaser_tests() -> void:
	var rows := _rows(FileAccess.get_file_as_string(PARITY))
	assert_eq(rows.size(), 60, "rows")
	var numbers := {}
	var titles := {}
	var problems: Array = []
	var reference := RegEx.create_from_string("(tests/test_\\w+\\.gd)::(test_\\w+)")
	var methods := {}
	for row: Array in rows:
		var id: String = row[0]
		var file_key := id.get_slice("-", 0)
		if not EXPECTED_COUNTS.has(file_key):
			problems.append("%s: unknown Phaser file" % id)
			continue
		if not numbers.has(file_key):
			numbers[file_key] = []
		numbers[file_key].append(int(id.get_slice("-", 1)))
		if titles.has(row[1]):
			problems.append("%s: same Phaser test as %s" % [id, titles[row[1]]])
		titles[row[1]] = id
		var target: String = row[2]
		if target.begins_with("dropped:"):
			if target.trim_prefix("dropped:").strip_edges().length() < 10:
				problems.append("%s: dropped without a reason" % id)
			continue
		var found := reference.search_all(target)
		if found.is_empty():
			problems.append("%s: no tests/test_x.gd::test_y reference and not dropped" % id)
		for hit: RegExMatch in found:
			var file := hit.get_string(1)
			if not methods.has(file):
				methods[file] = _test_methods("res://" + file)
			if not (methods[file] as Array).has(hit.get_string(2)):
				problems.append("%s: %s::%s does not exist" % [id, file, hit.get_string(2)])
	for file_key: String in EXPECTED_COUNTS:
		var expected: Array = range(1, int(EXPECTED_COUNTS[file_key]) + 1)
		var got: Array = numbers.get(file_key, [])
		got.sort()
		assert_eq(got, expected, "%s.test.ts rows" % file_key)
	assert_eq(problems, [])


## [id, Phaser test, GDScript test] for each row of the "Rule tests" table.
static func _rows(markdown: String) -> Array:
	var rows: Array = []
	var id := RegEx.create_from_string("^[a-z]+-\\d+$")
	for line in markdown.split("\n"):
		if not line.begins_with("|"):
			continue
		var cells := line.strip_edges().trim_prefix("|").trim_suffix("|").split("|")
		if cells.size() < 4:
			continue
		var first := cells[0].strip_edges()
		if id.search(first) != null:
			rows.append([first, cells[1].strip_edges(), cells[2].strip_edges()])
	return rows


static func _test_methods(path: String) -> Array:
	var names: Array = []
	if not FileAccess.file_exists(path):
		return names
	var script := ResourceLoader.load(path) as Script
	if script == null:
		return names
	for method: Dictionary in script.get_script_method_list():
		names.append(method["name"])
	return names
