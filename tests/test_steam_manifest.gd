extends "res://tests/test_case.gd"
## The Steam side of the game's files (B4; docs/GODOT_PLAN.md §5, docs/STEAM_INPUT.md): the action manifest
## steam_input/steam_input_manifest.vdf and its configurations (KeyValues text, parsed here), the export presets with
## and without Steam, GodotSteam's .gdextension and the inventory of addons/godotsteam/ in ASSETS.md (each file with
## its SHA-256). The manifest's sets and actions must be the adapter's (scripts/input/steam_input.gd ACTIONS): Steam
## gives no handle for a name it does not know, and the controller would do nothing.

const SteamInput := preload("res://scripts/input/steam_input.gd")

const DIR := "res://steam_input/"
const MANIFEST := "res://steam_input/steam_input_manifest.vdf"
const ADDON := "res://addons/godotsteam"
const GDEXTENSION := "res://addons/godotsteam/godotsteam.gdextension"
const ASSETS_MD := "res://ASSETS.md"
const README := "res://README.md"
const PRESETS := "res://export_presets.cfg"
## The controller types with a configuration of the game's own: Xbox, PlayStation, Switch Pro, the Steam Controller,
## the Steam Deck and generic gamepads (Valve's names, Steamworks "Action Manifest Files").
const CONFIGURED := [
	"controller_xbox360", "controller_xboxone", "controller_ps4", "controller_ps5", "controller_switch_pro",
	"controller_generic", "controller_steamcontroller_gordon", "controller_neptune",
]
## Every controller type Steamworks lists for an action manifest.
const VALVE_TYPES := [
	"controller_neptune", "controller_steamcontroller_gordon", "controller_xbox360", "controller_xboxone",
	"controller_xboxelite", "controller_ps3", "controller_ps4", "controller_ps5", "controller_ps5_edge",
	"controller_switch_pro", "controller_switch2_pro", "controller_switch_joycon_left", "controller_switch_joycon_right",
	"controller_switch_joycon_pair", "controller_mobile_touch", "controller_generic",
]
const LANGUAGES := ["english", "spanish"]
const LICENCES := ["MIT", "Steamworks SDK"]
## Godot's metadata next to a file, not shipped content.
const METADATA_EXTENSIONS := ["uid", "import"]


func test_the_manifest_has_configurations_actions_and_localization() -> void:
	var root: Variant = parse_vdf(FileAccess.get_file_as_string(MANIFEST))
	assert_true(root is Array, "the manifest parses")
	if not (root is Array):
		return
	assert_eq((root as Array).size(), 1)
	assert_eq(root[0][0], "Action Manifest")
	var manifest: Array = root[0][1]
	for section: String in ["configurations", "actions", "localization"]:
		assert_true(vdf_get(manifest, section) is Array, section)


## The sets are the adapter's, with exactly its digital actions; no analog action (the adapter reads none). No action
## name is in two sets: Steam's getDigitalActionHandle() takes no set, so it would ignore one of the two.
func test_the_manifest_sets_are_the_adapters() -> void:
	var actions: Array = vdf_get(_manifest(), "actions")
	var sets: Array = []
	for pair: Array in actions:
		sets.append(pair[0])
	assert_eq(sets, SteamInput.ACTIONS.keys())
	var names: Array = []
	for set_name: String in SteamInput.ACTIONS:
		var set_block: Array = vdf_get(actions, set_name)
		assert_true((vdf_get(set_block, "title") as String).begins_with("#"), set_name)
		var buttons: Array = []
		for pair: Array in vdf_get(set_block, "Button"):
			buttons.append(pair[0])
			assert_true((pair[1] as String).begins_with("#"), "%s %s has a localized title" % [set_name, pair[0]])
			assert_does_not_have(names, (pair[0] as String).to_lower(), "%s is in two sets" % pair[0])
			names.append((pair[0] as String).to_lower())
		assert_eq(buttons, (SteamInput.ACTIONS[set_name] as Dictionary).keys(), set_name)
		assert_eq(vdf_get(set_block, "StickPadGyro"), [], "%s: no analog action" % set_name)
		assert_eq(vdf_get(set_block, "AnalogTrigger"), [], "%s: no trigger action" % set_name)
	assert_eq(names.size(), 16)


## Every title token of the manifest has its text in English and Spanish, and so do the configurations' title and
## description.
func test_every_title_has_english_and_spanish_text() -> void:
	var manifest := _manifest()
	var tokens: Array = ["Title_Default", "Description_Default"]
	for set_pair: Array in vdf_get(manifest, "actions"):
		tokens.append((vdf_get(set_pair[1], "title") as String).trim_prefix("#"))
		for pair: Array in vdf_get(set_pair[1], "Button"):
			tokens.append((pair[1] as String).trim_prefix("#"))
	var localization: Array = vdf_get(manifest, "localization")
	for language: String in LANGUAGES:
		var texts: Variant = vdf_get(localization, language)
		assert_true(texts is Array, language)
		if not (texts is Array):
			continue
		var missing: Array = []
		for token: String in tokens:
			var text: Variant = vdf_get(texts, token)
			if not (text is String) or (text as String).is_empty():
				missing.append(token)
		assert_eq(missing, [], "%s texts missing" % language)


## Each controller type of CONFIGURED points to its own file next to the manifest, a configuration of that type.
func test_each_controller_type_has_its_configuration() -> void:
	var configurations: Array = vdf_get(_manifest(), "configurations")
	var types: Array = []
	for pair: Array in configurations:
		types.append(pair[0])
		assert_has(VALVE_TYPES, pair[0])
		var path: Variant = vdf_get(vdf_get(pair[1], "0"), "path")
		assert_eq(path, "%s.vdf" % pair[0], "the path is relative to the manifest")
		var config := _configuration(DIR + str(path))
		assert_eq(vdf_get(config, "controller_type"), pair[0], str(path))
		assert_eq(vdf_get(config, "version"), "3")
	types.sort()
	var expected := CONFIGURED.duplicate()
	expected.sort()
	assert_eq(types, expected)


## Each configuration repeats the manifest's actions, has one preset per action set, binds only that set's actions in
## it, binds every one of them, and uses its controller's input sources.
func test_each_configuration_binds_every_action_of_both_sets() -> void:
	var manifest_actions: Array = vdf_get(_manifest(), "actions")
	for type: String in CONFIGURED:
		var config := _configuration(DIR + type + ".vdf")
		var actions: Array = vdf_get(config, "actions")
		assert_eq(_set_actions(actions), _set_actions(manifest_actions), "%s repeats the manifest's actions" % type)
		var layout := bound(config)
		assert_eq(layout.keys(), SteamInput.ACTIONS.keys(), "%s: one preset per set" % type)
		for set_name: String in layout:
			var bound_actions: Array = []
			for where: String in layout[set_name]:
				var source := where.get_slice(".", 0)
				assert_has(sources_of(type), source, "%s %s" % [type, where])
				for action: String in layout[set_name][where]:
					assert_has((SteamInput.ACTIONS[set_name] as Dictionary).keys(), action, "%s %s %s" % [type, set_name, where])
					if not bound_actions.has(action):
						bound_actions.append(action)
			bound_actions.sort()
			var all: Array = (SteamInput.ACTIONS[set_name] as Dictionary).keys()
			all.sort()
			assert_eq(bound_actions, all, "%s binds every %s action" % [type, set_name])


## The default layout is the gamepad mapping of pads.gd and nav.gd, on every controller: A nitro and confirm, B
## accelerate (as a pad's B), the D-pad and the left stick steer, accelerate (up) and brake (down), Start pauses, Back
## (View, Select) goes back; in the menus A confirms, B leaves a seat, the D-pad and the stick move, Start starts the
## race, Back goes to the title. The 2015 Steam Controller has its left trackpad for the D-pad.
func test_the_default_layout_is_the_gamepad_mapping() -> void:
	for type: String in CONFIGURED:
		var pad := "left_trackpad" if type == "controller_steamcontroller_gordon" else "dpad"
		var expected := {
			SteamInput.RACING: {
				"button_diamond.button_A": ["confirm", "high_gear"],
				"button_diamond.button_B": ["accelerate"],
				"switch.button_escape": ["pause"],
				"switch.button_menu": ["back"],
			},
			SteamInput.MENUS: {
				"button_diamond.button_A": ["menu_confirm"],
				"button_diamond.button_B": ["menu_back"],
				"switch.button_escape": ["menu_start"],
				"switch.button_menu": ["menu_quit"],
			},
		}
		for source: String in [pad, "joystick"]:
			for direction: String in ["north", "south", "west", "east"]:
				var racing: String = {"north": "accelerate", "south": "brake", "west": "steer_left", "east": "steer_right"}[direction]
				expected[SteamInput.RACING]["%s.dpad_%s" % [source, direction]] = [racing]
				expected[SteamInput.MENUS]["%s.dpad_%s" % [source, direction]] = ["menu_" + {
					"north": "up", "south": "down", "west": "left", "east": "right"
				}[direction]]
		var layout := bound(_configuration(DIR + type + ".vdf"))
		for set_name: String in expected:
			var got: Dictionary = layout.get(set_name, {})
			var want: Dictionary = expected[set_name]
			var got_keys := got.keys()
			got_keys.sort()
			var want_keys := want.keys()
			want_keys.sort()
			assert_eq(got_keys, want_keys, "%s %s inputs" % [type, set_name])
			for where: String in want:
				var actions: Array = (got.get(where, []) as Array).duplicate()
				actions.sort()
				assert_eq(actions, want[where], "%s %s %s" % [type, set_name, where])


## The presets of A3 stay the builds without Steam and leave GodotSteam out (plan §5); the Steam builds are the same
## presets with it in, exported to folders of their own.
func test_the_export_presets_with_and_without_steam() -> void:
	var config := ConfigFile.new()
	assert_eq(config.load(PRESETS), OK)
	var presets := {}
	for section: String in config.get_sections():
		if section.begins_with("preset.") and not section.ends_with(".options"):
			presets[config.get_value(section, "name")] = section
	var names := presets.keys()
	names.sort()
	assert_eq(names, ["Linux", "Linux Steam", "Windows Desktop", "Windows Steam"])
	var pairs := {"Linux": "Linux Steam", "Windows Desktop": "Windows Steam"}
	for plain: String in pairs:
		var steam: String = pairs[plain]
		var a: String = presets[plain]
		var b: String = presets[steam]
		assert_eq(config.get_value(a, "exclude_filter"), "tests/*, tools/*, docs/*, addons/godotsteam/*", plain)
		assert_eq(config.get_value(b, "exclude_filter"), "tests/*, tools/*, docs/*", steam)
		for key: String in config.get_section_keys(a):
			if key in ["name", "exclude_filter", "export_path"]:
				continue
			assert_eq(config.get_value(b, key), config.get_value(a, key), "%s %s" % [steam, key])
		for key: String in config.get_section_keys(a + ".options"):
			assert_eq(config.get_value(b + ".options", key), config.get_value(a + ".options", key), "%s %s" % [steam, key])
		assert_eq(config.get_section_keys(b).size(), config.get_section_keys(a).size())
		assert_eq(config.get_section_keys(b + ".options").size(), config.get_section_keys(a + ".options").size())
		assert_true(config.get_value(b + ".options", "binary_format/embed_pck"), steam)
	assert_eq(config.get_value(presets["Linux Steam"], "export_path"), "build/linux_steam/fuel_rivals.x86_64")
	assert_eq(config.get_value(presets["Windows Steam"], "export_path"), "build/windows_steam/fuel_rivals.exe")
	assert_eq(config.get_value("runnable_presets", "Linux"), "Linux", "the runnable presets stay A3's")
	assert_eq(config.get_value("runnable_presets", "Windows Desktop"), "Windows Desktop")


## GodotSteam's .gdextension loads only the libraries shipped here: Linux and Windows x86_64, debug and release, each
## with Valve's Steam API next to it.
func test_the_gdextension_names_only_the_shipped_libraries() -> void:
	if not DirAccess.dir_exists_absolute(ADDON):
		assert_false(FileAccess.file_exists(GDEXTENSION), "a build without Steam")
		return
	var config := ConfigFile.new()
	assert_eq(config.load(GDEXTENSION), OK)
	assert_eq(config.get_value("configuration", "entry_symbol"), "godotsteam_init")
	assert_eq(config.get_value("configuration", "compatibility_minimum"), "4.4")
	var libraries := config.get_section_keys("libraries")
	libraries.sort()
	assert_eq(libraries, PackedStringArray([
		"linux.debug.x86_64", "linux.release.x86_64", "windows.debug.x86_64", "windows.release.x86_64"
	]))
	for key: String in libraries:
		assert_true(FileAccess.file_exists(config.get_value("libraries", key)), key)
	var dependencies := config.get_section_keys("dependencies")
	dependencies.sort()
	assert_eq(dependencies, PackedStringArray(["linux.x86_64", "windows.x86_64"]))
	for key: String in dependencies:
		var files: Dictionary = config.get_value("dependencies", key)
		assert_eq(files.size(), 1, key)
		for path: String in files:
			assert_true(FileAccess.file_exists(path), path)


## The adapter starts Steam itself (steamInitEx(480, true)). project.godot keeps GodotSteam's own settings at their
## defaults (no [steam] section): with "initialize_on_startup" on, GodotSteam would start Steam first and the adapter's
## call would log "Steam is already initialized." as an ERROR.
func test_godotsteam_does_not_start_steam_by_itself() -> void:
	var project := ConfigFile.new()
	assert_eq(project.load("res://project.godot"), OK)
	assert_true(project.has_section("application"), "project.godot read")
	assert_false(project.has_section("steam"), "no GodotSteam settings in project.godot")
	assert_false(ProjectSettings.get_setting("steam/initialization/processes/initialize_on_startup", false))


## ASSETS.md lists every file under addons/godotsteam/ with its SHA-256 and licence (MIT for GodotSteam, Valve's
## Steamworks SDK terms for its redistributables), and names no file that is not there. Without the folder (a tree
## without Steam) the table stays, describing the Steam builds.
func test_the_addon_files_are_listed_with_their_sha256() -> void:
	var rows := addon_rows(FileAccess.get_file_as_string(ASSETS_MD))
	assert_eq(rows.size(), 8, "the table of addons/godotsteam/")
	var bad: Array = []
	for row: Dictionary in rows:
		if not LICENCES.has(row["licence"]):
			bad.append("%s: licence %s" % [row["file"], row["licence"]])
		if (row["sha256"] as String).length() != 64:
			bad.append("%s: SHA-256 %s" % [row["file"], row["sha256"]])
	assert_eq(bad, [])
	if not DirAccess.dir_exists_absolute(ADDON):
		return
	var listed := {}
	for row: Dictionary in rows:
		listed[row["file"]] = row["sha256"]
	var wrong: Array = []
	for file: String in _files_under(ADDON):
		if METADATA_EXTENSIONS.has(file.get_extension()):
			continue
		var sha := FileAccess.get_sha256("res://" + file)
		if not listed.has(file):
			wrong.append("%s (SHA-256 %s) has no row" % [file, sha])
		elif listed[file] != sha:
			wrong.append("%s: the row says %s, the file is %s" % [file, listed[file], sha])
	for file: String in listed:
		if not FileAccess.file_exists("res://" + file):
			wrong.append("%s is listed but missing" % file)
	assert_eq(wrong, [])


## README.md (A3's), where B4 wrote about Steam: Export names the four presets, their folders and the steam_input/
## folder a Steam build needs; Layout lists the Steam files; the Steam section points to docs/STEAM_INPUT.md and gives
## the App ID, the one warning, --no-steam for the game and for the tests, and what is not tested yet.
func test_the_readme_describes_the_steam_builds_and_steam_input() -> void:
	var readme := FileAccess.get_file_as_string(README)
	var wanted := {
		"## Export": [
			"**Linux Steam**", "**Windows Steam**", "build/linux_steam/", "build/windows_steam/", "addons/godotsteam/",
			"the `steam_input/` folder", "docs/STEAM_INPUT.md",
		],
		"## Layout": [
			"addons/godotsteam/", "steam_input/ ", "steam_input (Steam's controllers)", "fake_steam.gd",
			"gen_steam_input.py (the files in steam_input/)", "STEAM_INPUT.md",
		],
		"## Steam": [
			"docs/STEAM_INPUT.md", "GodotSteam 4.23.1", "**480**", "(\"Steam Input is off\")", "`--no-steam`",
			"`tools/test.sh --no-steam`", "Not tested yet: a real Steam client",
		],
	}
	for heading: String in wanted:
		var section := markdown_section(readme, heading)
		assert_gt(section.length(), 200, heading)
		for piece: String in wanted[heading]:
			assert_true(section.contains(piece), "README.md %s says %s" % [heading, piece])
	assert_true(FileAccess.file_exists("res://docs/STEAM_INPUT.md"), "the page the README points to")
	assert_eq(markdown_section("# A\n## B\nb\n### C\nc\n## D\nd", "## B"), "## B\nb\n### C\nc\n", "the section reader")


## The VDF reader of these tests, on text written for it.
func test_the_vdf_reader() -> void:
	var text := "// comment\n\"a\" { \"b\" \"1\"  \"b\" \"2\" \"c\" { } unquoted value }\n\"d\" \"e \\\"q\\\"\""
	var root: Variant = parse_vdf(text)
	assert_eq(root, [["a", [["b", "1"], ["b", "2"], ["c", []], ["unquoted", "value"]]], ["d", "e \"q\""]])
	assert_eq(vdf_all(root[0][1], "B"), ["1", "2"], "keys match without case, as Steam's do")
	assert_null(parse_vdf("\"a\" { \"b\" \"1\""), "an unclosed block")
	assert_null(parse_vdf("\"a\" \"b\" }"), "a stray brace")
	assert_null(parse_vdf("\"a\""), "a key without a value")


# --- helpers ---------------------------------------------------------------------------------------------------------


## KeyValues (VDF) text as [[key, value], ...] in order, each value a String or such an Array; null if it does not
## parse. Quoted and unquoted tokens, braces, // comments and the escapes \" \\ \n \t.
static func parse_vdf(text: String) -> Variant:
	var tokens: Array = []
	var i := 0
	var n := text.length()
	while i < n:
		var c := text[i]
		if c == " " or c == "\t" or c == "\r" or c == "\n":
			i += 1
		elif c == "/" and i + 1 < n and text[i + 1] == "/":
			while i < n and text[i] != "\n":
				i += 1
		elif c == "{" or c == "}":
			tokens.append(c)
			i += 1
		elif c == "\"":
			var out := ""
			i += 1
			while i < n and text[i] != "\"":
				if text[i] == "\\" and i + 1 < n:
					var escaped := text[i + 1]
					out += {"n": "\n", "t": "\t"}.get(escaped, escaped)
					i += 2
				else:
					out += text[i]
					i += 1
			if i >= n:
				return null
			i += 1
			tokens.append([out])
		else:
			var start := i
			while i < n and not (text[i] in [" ", "\t", "\r", "\n", "{", "}", "\""]):
				i += 1
			tokens.append([text.substr(start, i - start)])
	var at: Array[int] = [0]
	var pairs: Variant = _vdf_pairs(tokens, at)
	if pairs == null or at[0] != tokens.size():
		return null
	return pairs


static func _vdf_pairs(tokens: Array, at: Array[int]) -> Variant:
	var out: Array = []
	while at[0] < tokens.size():
		var token: Variant = tokens[at[0]]
		if token is String and token == "}":
			return out
		if not (token is Array) or at[0] + 1 >= tokens.size():
			return null
		var key: String = token[0]
		var next: Variant = tokens[at[0] + 1]
		at[0] += 2
		if next is Array:
			out.append([key, next[0]])
		elif next == "{":
			var inner: Variant = _vdf_pairs(tokens, at)
			if inner == null or at[0] >= tokens.size() or tokens[at[0]] != "}":
				return null
			at[0] += 1
			out.append([key, inner])
		else:
			return null
	return out


## The first value of a key (keys match without case, as in Steam's KeyValues), or null.
static func vdf_get(pairs: Variant, key: String) -> Variant:
	if not (pairs is Array):
		return null
	for pair: Array in pairs:
		if (pair[0] as String).to_lower() == key.to_lower():
			return pair[1]
	return null


## Every value of a key, in order ([] if pairs is not a block).
static func vdf_all(pairs: Variant, key: String) -> Array:
	var out: Array = []
	if not (pairs is Array):
		return out
	for pair: Array in pairs:
		if (pair[0] as String).to_lower() == key.to_lower():
			out.append(pair[1])
	return out


## A configuration's bindings: action set -> {"source.input": [actions]}, through the set's preset (the groups active
## in it, each on its source). Every binding must be "game_action <set> <action>, <label>" of the preset's own set.
static func bound(config: Array) -> Dictionary:
	var groups := {}
	for group: Array in vdf_all(config, "group"):
		groups[vdf_get(group, "id")] = group
	var out := {}
	for preset: Array in vdf_all(config, "preset"):
		var set_name: String = vdf_get(preset, "name")
		var inputs := {}
		for pair: Array in vdf_get(preset, "group_source_bindings"):
			var words := (pair[1] as String).split(" ")
			if words.size() < 2 or words[1] != "active" or not groups.has(pair[0]):
				inputs["?%s" % pair[0]] = ["?unknown group or inactive: %s" % pair[1]]
				continue
			for input: Array in vdf_get(groups[pair[0]], "inputs"):
				var actions: Array = []
				for activator: Array in vdf_get(input[1], "activators"):
					for binding: String in vdf_all(vdf_get(activator[1], "bindings"), "binding"):
						var command := binding.get_slice(",", 0).split(" ")
						if command.size() == 3 and command[0] == "game_action" and command[1] == set_name:
							actions.append(command[2])
						else:
							actions.append("?" + binding)
				inputs["%s.%s" % [words[0], input[0]]] = actions
		out[set_name] = inputs
	return out


## The input sources each controller type has (Steam Input's names).
static func sources_of(type: String) -> Array:
	if type == "controller_steamcontroller_gordon":
		return ["button_diamond", "left_trackpad", "right_trackpad", "joystick", "left_trigger", "right_trigger", "switch", "gyro"]
	var out := ["button_diamond", "dpad", "joystick", "right_joystick", "left_trigger", "right_trigger", "switch"]
	if type in ["controller_ps4", "controller_ps5", "controller_switch_pro", "controller_neptune"]:
		out.append("gyro")
	if type == "controller_neptune":
		out.append_array(["left_trackpad", "right_trackpad"])
	return out


## A Markdown section: from its heading line (exactly `heading`) to the next heading of the same or a higher level,
## or "" if there is no such heading.
static func markdown_section(markdown: String, heading: String) -> String:
	var level := heading.get_slice(" ", 0)
	var out := ""
	var inside := false
	for line in markdown.split("\n"):
		if inside and line.begins_with("#"):
			var marks := line.get_slice(" ", 0)
			if marks.length() <= level.length() and marks == "#".repeat(marks.length()):
				break
		if line == heading:
			inside = true
		if inside:
			out += line + "\n"
	return out


## The rows of ASSETS.md's addon table (header "| Addon file | SHA-256 | Source | Licence | Use |").
static func addon_rows(markdown: String) -> Array:
	var lines := markdown.split("\n")
	var start := -1
	for i in lines.size():
		if lines[i].begins_with("| Addon file |"):
			start = i
			break
	var rows: Array = []
	if start < 0:
		return rows
	for i in range(start + 2, lines.size()):
		if not lines[i].begins_with("|"):
			break
		var cells: Array = []
		for cell in lines[i].trim_prefix("|").trim_suffix("|").split("|"):
			cells.append(cell.strip_edges().replace("`", ""))
		if cells.size() >= 5:
			rows.append({"file": cells[0], "sha256": cells[1], "licence": cells[3]})
	return rows


static func _files_under(root: String) -> Array:
	var out: Array = []
	for name in DirAccess.get_files_at(root):
		out.append((root + "/" + name).trim_prefix("res://"))
	for name in DirAccess.get_directories_at(root):
		out.append_array(_files_under(root + "/" + name))
	out.sort()
	return out


## Set -> its Button actions in order, from an "actions" block.
static func _set_actions(actions: Array) -> Dictionary:
	var out := {}
	for pair: Array in actions:
		var names: Array = []
		for action: Array in vdf_get(pair[1], "Button"):
			names.append(action[0])
		out[pair[0]] = names
	return out


func _manifest() -> Array:
	var root: Variant = parse_vdf(FileAccess.get_file_as_string(MANIFEST))
	return root[0][1] if root is Array and not (root as Array).is_empty() else []


func _configuration(path: String) -> Array:
	var root: Variant = parse_vdf(FileAccess.get_file_as_string(path))
	assert_true(root is Array and (root as Array).size() == 1 and root[0][0] == "controller_mappings", path)
	return root[0][1] if root is Array and not (root as Array).is_empty() else []
