extends RefCounted
## The six player colours (B2): one per seat, for good, on the join screen's cards, the cars, the HUD and the result
## panels. Every use goes through this file, so the set is changed here alone (docs/GODOT_PLAN.md §5).
##
## PROVISIONAL (B2a): these six are placeholders, picked by eye away from the traffic's yellow, salmon, blue and
## green-and-white truck. B2b chooses the final six with a measured minimum distance, writes test_colour_sets_disjoint
## and checks the versus screenshots by pixel sampling (plan §8 B2).
##
## Cars: car_red and its two 45-degree frames, recoloured. Each of car_red's three body reds (SOURCE) becomes the
## seat's shade of the same rank (SHADES), every other pixel stays (outline, windows, lights); add_frames() builds the
## copies once at boot, as ImageTextures in the atlas's frame map, named frame_name(). Seat 0 keeps car_red's own reds.

const ViewConfig := preload("res://scripts/view/view_config.gd")
const Atlas := preload("res://scripts/view/atlas.gd")

const COUNT := 6
const NAMES := ["RED", "PURPLE", "PINK", "TEAL", "WHITE", "BLACK"]
## car_red's body reds: body, dark, light.
const SOURCE := [Color("#ae2633"), Color("#611732"), Color("#f26864")]
## Per seat, the shades that replace SOURCE: body, dark, light.
const SHADES := [
	[Color("#ae2633"), Color("#611732"), Color("#f26864")],
	[Color("#7a3ec6"), Color("#3f2070"), Color("#b28af0")],
	[Color("#d6389a"), Color("#74184f"), Color("#f68cc8")],
	[Color("#179c8e"), Color("#0b4f48"), Color("#62dcc9")],
	[Color("#d9d6d2"), Color("#8c8781"), Color("#ffffff")],
	[Color("#3a3a40"), Color("#1c1c20"), Color("#6f6f78")],
]
## The frames that get a copy per seat: upright and turned 45 degrees each way (cars.gd player_sprite()).
const FRAMES := [ViewConfig.PLAYER, ViewConfig.PLAYER_SKID_LEFT, ViewConfig.PLAYER_SKID_RIGHT]


## The seat's colour: its cars' body colour, for swatches, card borders and gauges.
static func colour(seat: int) -> Color:
	return SHADES[seat][0]


## The seat's colour for text on a dark panel: its light shade.
static func text_colour(seat: int) -> Color:
	return SHADES[seat][2]


## How a seat is named on screen: P1 to P6 for a person's, BOT for a bot's (the colour tells bots apart).
static func label(seat: int, person: bool) -> String:
	return "P%d" % (seat + 1) if person else "BOT"


## The name of a seat's copy of a frame in the atlas's frame map.
static func frame_name(frame: String, seat: int) -> String:
	return "%s@p%d" % [frame, seat + 1]


## A sprite ({frame, shadow}, as view_config.gd's) in a seat's colour.
static func seat_sprite(spec: Dictionary, seat: int) -> Dictionary:
	return {"frame": frame_name(spec["frame"], seat), "shadow": spec["shadow"]}


## Adds every seat's copy of FRAMES to the atlas. False if a frame to copy is missing (the view then draws the
## seats' cars as flat rectangles in colour()).
static func add_frames(atlas: Atlas) -> bool:
	var ok := true
	for spec: Dictionary in FRAMES:
		var name: String = spec["frame"]
		var tex := atlas.frame(name) as AtlasTexture
		if tex == null or tex.atlas == null:
			ok = false
			continue
		var sheet := tex.atlas.get_image()
		if sheet == null:
			ok = false
			continue
		var image := sheet.get_region(Rect2i(tex.region))
		image.convert(Image.FORMAT_RGBA8)
		for seat in COUNT:
			atlas.frames[frame_name(name, seat)] = ImageTexture.create_from_image(recoloured(image, seat))
	return ok


## A copy of an image with SOURCE's colours swapped for the seat's SHADES. Pixels are compared as bytes.
static func recoloured(image: Image, seat: int) -> Image:
	var out := image.duplicate() as Image
	var shades: Array = SHADES[seat]
	for y in out.get_height():
		for x in out.get_width():
			var pixel := out.get_pixel(x, y)
			if pixel.a8 == 0:
				continue
			for i in SOURCE.size():
				var from: Color = SOURCE[i]
				if pixel.r8 == from.r8 and pixel.g8 == from.g8 and pixel.b8 == from.b8:
					var to: Color = shades[i]
					out.set_pixel(x, y, Color(to, pixel.a))
					break
	return out
