extends RefCounted
## Drawing primitives the screens share (src/render/draw.ts and src/render/text.ts in the Phaser version): pixel-font
## text with or without a hard shadow, boxes, panels, gauges and sprites placed on hitboxes. Every function draws on
## a CanvasItem from its _draw(), at whole pixels.
##
## Text: Press Start 2P at a multiple of 8 px. `top` is the y of the text's top edge; the font's ascent equals its
## size and it has no descent, so the baseline is top + size. The font is monospaced: a line is size px per character.

const ViewConfig := preload("res://scripts/view/view_config.gd")
const Atlas := preload("res://scripts/view/atlas.gd")


static func text(ci: CanvasItem, font: Font, x: int, top: int, s: String, size: int, colour: Color) -> void:
	ci.draw_string(font, Vector2(x, top + size), s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, colour)


static func text_width(font: Font, s: String, size: int) -> int:
	return roundi(font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x)


## Left x that centres a line on centre_x, on a whole pixel.
static func centred_x(font: Font, centre_x: int, s: String, size: int) -> int:
	return centre_x - floori(text_width(font, s, size) / 2.0)


static func text_centred(ci: CanvasItem, font: Font, centre_x: int, top: int, s: String, size: int, colour: Color) -> void:
	text(ci, font, centred_x(font, centre_x, s, size), top, s, size, colour)


## Text with a hard black drop shadow one font pixel (size / 8) down and to the right (shadowedText in Phaser).
static func shadowed(ci: CanvasItem, font: Font, x: int, top: int, s: String, size: int, colour: Color) -> void:
	var offset := shadow_offset(size)
	text(ci, font, x + offset, top + offset, s, size, Color(ViewConfig.BLACK, colour.a))
	text(ci, font, x, top, s, size, colour)


static func shadowed_centred(ci: CanvasItem, font: Font, centre_x: int, top: int, s: String, size: int, colour: Color) -> void:
	shadowed(ci, font, centred_x(font, centre_x, s, size), top, s, size, colour)


static func shadow_offset(size: int) -> int:
	return maxi(1, size >> 3)


## Splits text into lines of at most max_chars characters, breaking between words (Phaser's wordWrap).
static func wrap(s: String, max_chars: int) -> PackedStringArray:
	var lines := PackedStringArray()
	var line := ""
	for word: String in s.split(" ", false):
		if line.is_empty():
			line = word
		elif line.length() + 1 + word.length() <= max_chars:
			line += " " + word
		else:
			lines.append(line)
			line = word
	if not line.is_empty():
		lines.append(line)
	return lines


static func rect(ci: CanvasItem, r: Rect2i, colour: Color) -> void:
	ci.draw_rect(Rect2(r), colour)


## A box with a solid 2 px border and a dark fill (drawBox in Phaser), drawn with fills on whole pixels. Phaser's
## fill let 8 % of the picture through; here it is opaque by default, so nothing shows through the text.
static func box(ci: CanvasItem, r: Rect2i, border: Color = ViewConfig.YELLOW, fill_alpha: float = 1.0) -> void:
	var b := 2
	rect(ci, Rect2i(r.position.x + b, r.position.y + b, r.size.x - b * 2, r.size.y - b * 2), Color(ViewConfig.BLACK, fill_alpha))
	rect(ci, Rect2i(r.position.x, r.position.y, r.size.x, b), border)
	rect(ci, Rect2i(r.position.x, r.end.y - b, r.size.x, b), border)
	rect(ci, Rect2i(r.position.x, r.position.y + b, b, r.size.y - b * 2), border)
	rect(ci, Rect2i(r.end.x - b, r.position.y + b, b, r.size.y - b * 2), border)


## A vertical gauge filled from the bottom, drawn like the sheet's fuel gauge: a white rim, a black gap, then the
## bar (drawGauge in Phaser). fraction is clamped to 0..1.
static func gauge(ci: CanvasItem, r: Rect2i, fraction: float, fill: Color) -> void:
	var rim := 2
	var inset := rim * 2
	rect(ci, r, ViewConfig.WHITE)
	rect(ci, Rect2i(r.position.x + rim, r.position.y + rim, r.size.x - rim * 2, r.size.y - rim * 2), ViewConfig.BLACK)
	var full := r.size.y - inset * 2
	var height := roundi(full * clampf(fraction, 0.0, 1.0))
	rect(ci, Rect2i(r.position.x + inset, r.end.y - inset - height, r.size.x - inset * 2, height), fill)


## Top-left corner that centres a sprite's body (its frame without the shadow) on a hitbox, on whole pixels
## (placeOnHitbox in Phaser). Halves round up, as Math.round did.
static func place_on_hitbox(frame_size: Vector2i, shadow: int, scale: int, box_pos: Vector2i, box_size: Vector2i) -> Vector2i:
	var body := (frame_size - Vector2i(shadow, shadow)) * scale
	return Vector2i(
		box_pos.x + floori((box_size.x - body.x) / 2.0 + 0.5),
		box_pos.y + floori((box_size.y - body.y) / 2.0 + 0.5)
	)


## Draws a sprite ({frame, shadow}) centred on a hitbox at ViewConfig.SPRITE_SCALE, tinted by modulate. A missing
## frame draws the hitbox as a flat rectangle instead.
static func sprite_on_hitbox(
	ci: CanvasItem, atlas: Atlas, spec: Dictionary, box_pos: Vector2i, box_size: Vector2i, fallback: Color,
	modulate: Color = Color.WHITE
) -> void:
	var name: String = spec["frame"]
	var tex := atlas.frame(name) if atlas != null else null
	if tex == null:
		rect(ci, Rect2i(box_pos, box_size), fallback)
		return
	var size := Vector2i(tex.get_width(), tex.get_height())
	var at := place_on_hitbox(size, int(spec["shadow"]), ViewConfig.SPRITE_SCALE, box_pos, box_size)
	ci.draw_texture_rect(tex, Rect2(at, size * ViewConfig.SPRITE_SCALE), false, modulate)


## A frame at a whole-number scale with its top-left corner at pos. Nothing if the frame is missing.
static func frame_at(ci: CanvasItem, atlas: Atlas, name: String, pos: Vector2i, scale: int) -> void:
	var tex := atlas.frame(name) if atlas != null else null
	if tex != null:
		ci.draw_texture_rect(tex, Rect2(pos, Vector2i(tex.get_width(), tex.get_height()) * scale), false)
