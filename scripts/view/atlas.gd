extends RefCounted
## The game's art and font, loaded once at boot (docs/GODOT_PLAN.md §2, §5; BootScene and src/render/sprites.ts in
## the Phaser version).
##
## - assets/sprites.png is load()ed (never Image.load_from_file on res://, plan §2).
## - assets/sprites.json, a plain map of frame name -> {x, y, w, h}, is read with FileAccess and parsed with JSON, so
##   its numbers arrive as floats. Each frame becomes an AtlasTexture on the atlas.
## - The truck and the oil puddle, which the sheet lacks, come from pixel_art.gd.
## - Press Start 2P is load()ed with the flags of its .import file (no antialiasing, hinting or subpixel positioning).
##
## A frame that is missing or malformed is skipped with a warning; the view then draws a flat rectangle in its place,
## as the Phaser version did when its atlas failed to load.

const ViewConfig := preload("res://scripts/view/view_config.gd")
const PixelArt := preload("res://scripts/view/pixel_art.gd")

var texture: Texture2D
## Frame name -> Texture2D: AtlasTexture for the sheet's frames, ImageTexture for the code-drawn ones.
var frames: Dictionary = {}
var font: Font


## Loads everything. True when the atlas, every frame of its map and the font loaded.
func load_all() -> bool:
	var ok := _load_atlas()
	var drawn := PixelArt.textures()
	for name: String in drawn:
		frames[name] = drawn[name]
	ok = ok and drawn.size() == PixelArt.GRIDS.size()
	return _load_font() and ok


func has_frame(name: String) -> bool:
	return frames.has(name)


## The frame's texture, or null.
func frame(name: String) -> Texture2D:
	return frames.get(name) as Texture2D


## Size of a frame in texture pixels, or (0, 0) if there is no such frame.
func frame_size(name: String) -> Vector2i:
	var tex := frame(name)
	if tex == null:
		return Vector2i.ZERO
	return Vector2i(tex.get_width(), tex.get_height())


func _load_atlas() -> bool:
	if not ResourceLoader.exists(ViewConfig.ATLAS_PNG):
		push_warning("Atlas: %s is missing; the view draws rectangles" % ViewConfig.ATLAS_PNG)
		return false
	texture = load(ViewConfig.ATLAS_PNG) as Texture2D
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(ViewConfig.ATLAS_JSON))
	if texture == null or not (parsed is Dictionary):
		push_warning("Atlas: the atlas or its frame map did not load; the view draws rectangles")
		return false
	var map: Dictionary = parsed
	var ok := true
	for name: String in map:
		var rect := _rect_of(map[name])
		if rect.size.x <= 0 or rect.size.y <= 0:
			push_warning("Atlas: frame \"%s\" is malformed and was skipped" % name)
			ok = false
			continue
		var atlas_texture := AtlasTexture.new()
		atlas_texture.atlas = texture
		atlas_texture.region = Rect2(rect)
		atlas_texture.filter_clip = true
		frames[name] = atlas_texture
	return ok


## {x, y, w, h} with whole, non-negative numbers (JSON gives floats) as a Rect2i; an empty rect if malformed.
static func _rect_of(value: Variant) -> Rect2i:
	if not (value is Dictionary):
		return Rect2i()
	var entry: Dictionary = value
	var numbers: Array[int] = []
	for key: String in ["x", "y", "w", "h"]:
		var n: Variant = entry.get(key)
		if typeof(n) != TYPE_FLOAT and typeof(n) != TYPE_INT:
			return Rect2i()
		var f := float(n)
		if f != floorf(f) or f < 0.0:
			return Rect2i()
		numbers.append(int(f))
	return Rect2i(numbers[0], numbers[1], numbers[2], numbers[3])


func _load_font() -> bool:
	if ResourceLoader.exists(ViewConfig.FONT_FILE):
		font = load(ViewConfig.FONT_FILE) as Font
	if font == null:
		push_warning("Atlas: the pixel font did not load; text uses the engine's fallback font")
		font = ThemeDB.fallback_font
		return false
	return true
