extends "res://tests/test_case.gd"
## Plan §6 test_all_scripts_compile: every GDScript in the project loads and can be instantiated, with the
## project's warnings-as-errors (integer division, untyped declarations). Hidden folders and folders with a
## .gdignore are skipped, as Godot skips them.


func test_all_scripts_compile() -> void:
	var scripts := _gd_files("res://")
	assert_gt(scripts.size(), 15, "scripts found")
	assert_has(scripts, "res://scripts/sim/world.gd")
	assert_has(scripts, "res://tests/run_tests.gd")
	var broken: Array = []
	for path: String in scripts:
		var script := ResourceLoader.load(path) as Script
		if script == null or not script.can_instantiate():
			broken.append(path)
	assert_eq(broken, [], "scripts that do not compile")


static func _gd_files(root: String) -> Array:
	var out: Array = []
	var base := root if root.ends_with("/") else root + "/"
	if FileAccess.file_exists(base + ".gdignore"):
		return out
	for name in DirAccess.get_files_at(base):
		if name.ends_with(".gd"):
			out.append(base + name)
	for name in DirAccess.get_directories_at(base):
		if not name.begins_with("."):
			out.append_array(_gd_files(base + name))
	out.sort()
	return out
