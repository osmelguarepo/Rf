extends "res://tests/test_case.gd"
## Shipped assets (ASSETS.md) and the three render intentions kept from the Phaser render tests
## (docs/GODOT_PLAN.md §6): every frame used exists, every frame lies inside the atlas, and scales are whole numbers.
##
## The two checks on the view's code read scripts/view/ and scenes/ (A2's files) as text: frame names are string
## literals such as "car_red", and scales are constants or Vector2 values whose name contains "scale". They pass with
## nothing to check until that code exists.

const ASSETS_DIR := "res://assets"
const ASSETS_MD := "res://ASSETS.md"
const ATLAS_PNG := "res://assets/sprites.png"
const ATLAS_JSON := "res://assets/sprites.json"
const FONT_DIR := "res://assets/font"
const LICENCES := ["CC0-1.0", "OFL-1.1", "Own work"]
const AUDIO_EXTENSIONS := ["mp3", "wav", "ogg", "oga", "opus", "m4a", "flac", "aac", "aif", "aiff", "mid", "midi"]
## Godot's own metadata next to an asset, not shipped content.
const METADATA_EXTENSIONS := ["import", "uid"]
## Sprites that the sheet lacks and the view draws in code (ASSETS.md, "Art drawn in code"). A frame name the view
## uses must be an atlas frame or one of these.
const CODE_DRAWN := ["truck", "oil_puddle"]
## Folders that hold the game's drawing code and scenes.
const VIEW_SOURCES := ["res://scripts/view", "res://scenes"]


func test_assets_listed() -> void:
	var shipped := _shipped_files()
	assert_gt(shipped.size(), 3, "files under assets/")
	var rows := _inventory(FileAccess.get_file_as_string(ASSETS_MD))
	assert_gt(rows.size(), 0, "ASSETS.md has a | File | table")
	var listed: Array = []
	var incomplete: Array = []
	var unknown_licence: Array = []
	for row: Dictionary in rows:
		listed.append(row["file"])
		var cells: Array = row["cells"]
		if cells.size() < 5 or cells.has(""):
			incomplete.append(row["file"])
		if not LICENCES.has(row["licence"]):
			unknown_licence.append("%s: %s" % [row["file"], row["licence"]])
	var unlisted: Array = []
	for file: String in shipped:
		if not listed.has(file):
			unlisted.append(file)
	var missing: Array = []
	for file: String in listed:
		if not FileAccess.file_exists("res://" + file):
			missing.append(file)
	assert_eq(unlisted, [], "shipped files without a row in ASSETS.md")
	assert_eq(missing, [], "rows naming files that do not exist")
	assert_eq(incomplete, [], "rows with an empty cell")
	assert_eq(unknown_licence, [], "rows with a licence other than %s" % ", ".join(LICENCES))


## Plan §5: no audio. No audio file anywhere in the repository, and no audio class in the game's code or scenes.
func test_no_audio() -> void:
	var audio_files: Array = []
	for file: String in _walk("res://", false):
		if AUDIO_EXTENSIONS.has(file.get_extension().to_lower()):
			audio_files.append(file)
	assert_eq(audio_files, [], "audio files")
	var classes := RegEx.create_from_string("\\bAudio(Stream|Server|Listener|Effect|Bus)\\w*")
	var uses: Array = []
	for root: String in ["res://scripts", "res://scenes"]:
		for file: String in _walk(root, true):
			if file.get_extension() in ["gd", "tscn", "tres"]:
				if classes.search(FileAccess.get_file_as_string("res://" + file)) != null:
					uses.append(file)
	assert_eq(uses, [], "audio classes in scripts/ or scenes/")


## Render intention 2: every frame of sprites.json lies inside sprites.png (size read from the PNG header).
func test_atlas_frames_lie_inside_the_atlas() -> void:
	var size := _png_size(ATLAS_PNG)
	assert_eq(size.size(), 2, "sprites.png has a PNG header")
	var frames := _frames()
	assert_gt(frames.size(), 0, "frames in sprites.json")
	if size.size() != 2:
		return
	var outside: Array = []
	for name: String in frames:
		var f: Dictionary = frames[name]
		var values: Array = [f.get("x"), f.get("y"), f.get("w"), f.get("h")]
		var whole := true
		for value: Variant in values:
			whole = whole and typeof(value) == TYPE_FLOAT and float(value) == floorf(value)
		if not whole:
			outside.append("%s: %s" % [name, values])
			continue
		var x := int(f["x"])
		var y := int(f["y"])
		var w := int(f["w"])
		var h := int(f["h"])
		if w <= 0 or h <= 0 or x < 0 or y < 0 or x + w > size[0] or y + h > size[1]:
			outside.append("%s %s in %dx%d" % [name, values, size[0], size[1]])
	assert_eq(outside, [], "frames outside the atlas")


## Render intention 1: every frame name in the view's code or scenes is an atlas frame or drawn in code.
func test_frames_used_by_the_view_exist() -> void:
	var frames := _frames()
	assert_gt(frames.size(), 0, "frames in sprites.json")
	var known: Array = frames.keys()
	known.append_array(CODE_DRAWN)
	var prefixes := {}
	for name: String in known:
		prefixes[name.get_slice("_", 0)] = true
	var literal := RegEx.create_from_string("[\"']([a-z][a-z0-9]*(?:_[a-z0-9]+)*)[\"']")
	var unknown: Array = []
	for root: String in VIEW_SOURCES:
		for file: String in _walk(root, true):
			if not (file.get_extension() in ["gd", "tscn", "tres"]):
				continue
			for found: RegExMatch in literal.search_all(FileAccess.get_file_as_string("res://" + file)):
				var name := found.get_string(1)
				var looks_like_frame := name.contains("_") and prefixes.has(name.get_slice("_", 0))
				if looks_like_frame and not known.has(name):
					unknown.append("%s (%s)" % [name, file])
	assert_eq(unknown, [], "frame names that are not in sprites.json and not drawn in code")


## Render intention 3: scales in the view's code and scenes are whole numbers, so pixels stay square.
func test_view_scales_are_whole_numbers() -> void:
	var number := "(-?[0-9]+(?:\\.[0-9]+)?)"
	var scalar := RegEx.create_from_string("(?i)\\b\\w*scale\\w*\\s*(?::\\s*\\w+)?\\s*:?=\\s*" + number + "\\s*($|#)")
	var vector := RegEx.create_from_string(
		"(?i)\\b\\w*scale\\w*\\s*(?::\\s*\\w+)?\\s*:?=\\s*Vector2i?\\(\\s*" + number + "\\s*,\\s*" + number + "\\s*\\)"
	)
	var bad: Array = []
	var checked := 0
	for root: String in VIEW_SOURCES:
		for file: String in _walk(root, true):
			if not (file.get_extension() in ["gd", "tscn", "tres"]):
				continue
			for line: String in FileAccess.get_file_as_string("res://" + file).split("\n"):
				var values: Array = []
				var one := scalar.search(line)
				if one != null:
					values.append(one.get_string(1))
				var two := vector.search(line)
				if two != null:
					values.append_array([two.get_string(1), two.get_string(2)])
				for text: String in values:
					checked += 1
					if not (text.is_valid_float() and float(text) >= 1.0 and float(text) == floorf(float(text))):
						bad.append("%s: %s" % [file, line.strip_edges()])
	assert_eq(bad, [], "scales that are not whole numbers >= 1 (%d checked)" % checked)


func test_font_ships_with_its_licence() -> void:
	var font := FONT_DIR + "/press-start-2p-latin-400-normal.woff2"
	var bytes := FileAccess.get_file_as_bytes(font)
	assert_eq(bytes.slice(0, 4).get_string_from_ascii(), "wOF2", "a real WOFF2 file")
	var licence := FileAccess.get_file_as_string(FONT_DIR + "/OFL.txt")
	assert_true(licence.contains("SIL OPEN FONT LICENSE Version 1.1"))
	assert_true(licence.contains("Press Start 2P"))


# --- helpers ---------------------------------------------------------------------------------------------------------


## Files under assets/ that ship: not in a folder with .gdignore, not Godot's .import/.uid metadata.
static func _shipped_files() -> Array:
	var out: Array = []
	for file: String in _walk(ASSETS_DIR, true):
		if not METADATA_EXTENSIONS.has(file.get_extension()) and file.get_file() != ".gdignore":
			out.append(file)
	return out


## Repository-relative paths of the files under a res:// folder, sorted. Hidden folders (.godot, .git) are always
## skipped; folders with a .gdignore are skipped when skip_ignored is true.
static func _walk(root: String, skip_ignored: bool) -> Array:
	var out: Array = []
	if not DirAccess.dir_exists_absolute(root):
		return out
	var base := root if root.ends_with("/") else root + "/"
	if skip_ignored and FileAccess.file_exists(base + ".gdignore"):
		return out
	for name in DirAccess.get_files_at(base):
		out.append((base + name).trim_prefix("res://"))
	for name in DirAccess.get_directories_at(base):
		if not name.begins_with("."):
			out.append_array(_walk(base + name, skip_ignored))
	out.sort()
	return out


## Rows of the ASSETS.md table whose header starts with "| File |": {file, licence, cells}.
static func _inventory(markdown: String) -> Array:
	var lines := markdown.split("\n")
	var start := -1
	for i in lines.size():
		if RegEx.create_from_string("^\\|\\s*File\\s*\\|").search(lines[i]) != null:
			start = i
			break
	if start < 0:
		return []
	var header := _cells(lines[start])
	var licence_column := header.find("Licence")
	var rows: Array = []
	for i in range(start + 2, lines.size()):
		if not lines[i].strip_edges().begins_with("|"):
			break
		var cells := _cells(lines[i])
		rows.append({
			"file": cells[0].replace("`", ""),
			"licence": cells[licence_column] if licence_column >= 0 and licence_column < cells.size() else "",
			"cells": cells,
		})
	return rows


static func _cells(line: String) -> Array:
	var text := line.strip_edges().trim_prefix("|").trim_suffix("|")
	var out: Array = []
	for cell in text.split("|"):
		out.append(cell.strip_edges())
	return out


## Width and height from the IHDR chunk, which the PNG format puts first; [] if the file is not a PNG.
static func _png_size(path: String) -> Array:
	var bytes := FileAccess.get_file_as_bytes(path)
	var signature := PackedByteArray([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
	if bytes.size() < 24 or bytes.slice(0, 8) != signature or bytes.slice(12, 16).get_string_from_ascii() != "IHDR":
		return []
	return [_u32_big_endian(bytes, 16), _u32_big_endian(bytes, 20)]


static func _u32_big_endian(bytes: PackedByteArray, at: int) -> int:
	return (bytes[at] << 24) | (bytes[at + 1] << 16) | (bytes[at + 2] << 8) | bytes[at + 3]


static func _frames() -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(ATLAS_JSON))
	return parsed if parsed is Dictionary else {}
