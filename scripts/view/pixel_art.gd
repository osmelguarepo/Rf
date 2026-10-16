extends RefCounted
## Sprites the GrafxKid sheet does not have, drawn in code as pixel grids (src/render/pixelArt.ts in the Phaser
## version, docs/ART_PLAN.md §2). This art is the project's own work (ASSETS.md, "Art drawn in code"). Its colours
## are picked from the sheet, so it matches the sheet's sprites.
##
## One character is one texture pixel and '.' is transparent. The view draws these textures at
## ViewConfig.SPRITE_SCALE like every other sprite.

const PALETTE := {
	"k": Color("#141414"),  # black: shadows, oil
	"w": Color("#f0eeec"),  # white
	"u": Color("#a69f96"),  # light grey
	"q": Color("#383838"),  # dark grey
	"m": Color("#32384a"),  # windscreen, dark
	"n": Color("#4f6872"),  # windscreen, light
	"g": Color("#42ad37"),  # green
	"G": Color("#206348"),  # dark green
	"h": Color("#b4e357"),  # light green
}

## Box truck seen from above: green cab at the top, white container with ribs behind it. Body 10x20 with a 1 px
## shadow on the right and bottom, like the sheet's cars. At 2x the body is 20x40, the 18x40 hitbox plus 1 px a side.
const TRUCK := [
	"..GggggG...",
	".GwggggwG..",
	".Ggggggggk.",
	".Gmmmmmmgk.",
	".Gmnnnnmgk.",
	".Ghhhhhhgk.",
	".Ggggggggk.",
	"..GGGGGGkk.",
	"..qqqqqqk..",
	"quwwwwwwuq.",
	"quwwwwwwuqk",
	"quuuuuuuuqk",
	"quwwwwwwuqk",
	"quwwwwwwuqk",
	"quuuuuuuuqk",
	"quwwwwwwuqk",
	"quwwwwwwuqk",
	"quuuuuuuuqk",
	"quwwwwwwuqk",
	"qqqqqqqqqqk",
	".kkkkkkkkkk",
]

## Oil puddle with a shine and a drop, in the style of the sheet's 6x6 oil_spill, which is too small. 10x6 with no
## shadow (it lies flat on the road); at 2x it is 20x12, the 18x12 hitbox plus 1 px a side.
const OIL_PUDDLE := [
	"...kkkk...",
	".kkwkkkkk.",
	"kkkkkkkkkk",
	"kkkkkkkkkk",
	".kkkkkkkk.",
	"...kkk...k",
]

## Frame name -> grid. The names are the frames view_config.gd uses (and CODE_DRAWN in tests/test_assets.gd).
const GRIDS := {"truck": TRUCK, "oil_puddle": OIL_PUDDLE}


## The grid as an RGBA image, one pixel per character. A ragged grid or a character outside the palette logs an
## error and returns null, so a typo shows at boot instead of drawing garbage.
static func to_image(rows: Array) -> Image:
	if rows.is_empty() or str(rows[0]).is_empty():
		push_error("PixelArt: empty grid")
		return null
	var width := str(rows[0]).length()
	var image := Image.create_empty(width, rows.size(), false, Image.FORMAT_RGBA8)
	for y in rows.size():
		var row := str(rows[y])
		if row.length() != width:
			push_error("PixelArt: row %d is %d wide, expected %d" % [y, row.length(), width])
			return null
		for x in width:
			var key := row[x]
			if key == ".":
				image.set_pixel(x, y, Color(0, 0, 0, 0))
			elif PALETTE.has(key):
				image.set_pixel(x, y, PALETTE[key])
			else:
				push_error("PixelArt: row %d uses '%s', which is not in the palette" % [y, key])
				return null
	return image


## Every grid of GRIDS as a texture, by frame name. Grids that fail to parse are left out.
static func textures() -> Dictionary:
	var out := {}
	for name: String in GRIDS:
		var image := to_image(GRIDS[name])
		if image != null:
			out[name] = ImageTexture.create_from_image(image)
	return out
