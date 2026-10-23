extends "res://tests/test_case.gd"
## Project configuration (docs/GODOT_PLAN.md §2): project.godot keys, the font import flags, .gitignore and the
## folders Godot must not import.

const PROJECT := "res://project.godot"
const FONT_IMPORT := "res://assets/font/press-start-2p-latin-400-normal.woff2.import"

## Section, key and value, exactly as the plan lists them.
const SETTINGS := [
	["application", "config/name", "Fuel Rivals"],
	["display", "window/size/viewport_width", 640],
	["display", "window/size/viewport_height", 360],
	["display", "window/size/window_width_override", 1920],
	["display", "window/size/window_height_override", 1080],
	["display", "window/stretch/mode", "viewport"],
	["display", "window/stretch/scale_mode", "integer"],
	["rendering", "renderer/rendering_method", "gl_compatibility"],
	["rendering", "renderer/rendering_method.mobile", "gl_compatibility"],
	["rendering", "textures/canvas_textures/default_texture_filter", 0],
	["rendering", "2d/snap/snap_2d_transforms_to_pixel", true],
	["debug", "gdscript/warnings/integer_division", 2],
	["debug", "gdscript/warnings/untyped_declaration", 2],
]


func test_project_settings() -> void:
	var config := ConfigFile.new()
	assert_eq(config.load(PROJECT), OK, "project.godot parses")
	for entry: Array in SETTINGS:
		var key := "%s/%s" % [entry[0], entry[1]]
		assert_eq(config.get_value(entry[0], entry[1], null), entry[2], key + " in project.godot")
	# The running engine sees the same values (the editor binary under --headless).
	for key: String in ["application/config/name", "display/window/size/viewport_width",
			"display/window/stretch/scale_mode", "rendering/textures/canvas_textures/default_texture_filter",
			"debug/gdscript/warnings/untyped_declaration"]:
		var parts := key.split("/", true, 1)
		assert_eq(ProjectSettings.get_setting(key), config.get_value(parts[0], parts[1], null), key + " as loaded")


## Plan §2: the pixel font is imported with antialiasing, hinting and subpixel positioning off.
func test_font_import_keeps_pixels_sharp() -> void:
	var config := ConfigFile.new()
	assert_eq(config.load(FONT_IMPORT), OK, "the font's .import is committed")
	assert_eq(config.get_value("params", "antialiasing", -1), 0)
	assert_eq(config.get_value("params", "hinting", -1), 0)
	assert_eq(config.get_value("params", "subpixel_positioning", -1), 0)


func test_gitignore_keeps_build_outputs_out() -> void:
	var lines: Array = []
	for line in FileAccess.get_file_as_string("res://.gitignore").split("\n"):
		lines.append(line.strip_edges())
	for entry: String in [".godot/", "build/", "shots/"]:
		assert_has(lines, entry)


## Folders that are not part of the game carry a .gdignore, so Godot neither imports nor exports them: the source
## sheet, the TypeScript generator of the golden traces, and docs/ (screenshots live in docs/screenshots/).
func test_non_game_folders_are_ignored_by_godot() -> void:
	for folder: String in ["res://assets/source", "res://tools/gen_golden", "res://docs"]:
		assert_true(FileAccess.file_exists(folder + "/.gdignore"), folder)
