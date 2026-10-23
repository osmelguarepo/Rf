extends RefCounted
## The six player colours (B2): one per seat, for good, on the cars, the join screen's cards, the HUD and the result
## panels. Every use goes through this file, so the set is changed here alone (docs/GODOT_PLAN.md §5).
##
## Cars: car_red and its two 45-degree frames, recoloured. Each of car_red's three body reds (SOURCE) becomes the
## seat's shade of the same rank (SHADES: body, dark, light); every other pixel stays (the windows, the lights, the
## shadow). add_frames() builds the copies once at boot, as ImageTextures in the atlas's frame map, named frame_name().
##
## How the six were chosen (docs/HANDOFF.md, B2 part 2, has the numbers). Players are told apart only by the colour of
## their car, and no player colour may be a traffic colour (docs/DECISIONES_MULTIJUGADOR.md §2). The traffic is yellow
## and orange (the small car), salmon (car_salmon, the "red" car), sky and royal blue with cyan (car_blue), green,
## lime, white and greys (the truck), black (oil), plus the windows, lights and shadow every car shares; the fuel car
## (car_police, tinted through the rainbow) is the declared exception. That leaves roses, pinks, plums, lilacs, a brown
## and a band of teal. The six are three hue families at two lightness levels, so any two differ in hue or in
## lightness: RUBY (a red leaning to rose: a true red is the salmon car's) and PINK, BROWN, LILAC, TEAL, and PLUM. BROWN replaced a purple (B2 review): under protan and deutan vision the purple folded onto the blue traffic car (CIEDE2000 2.0), while the brown stays at least 11 from every traffic colour and every other seat under normal, protan and deutan vision.
## Distances are CIEDE2000 (delta_e()) between sRGB colours, and tests/test_seat_colours.gd checks them on the pixels
## of the frames: every seat colour at least MIN_SHADE_TO_TRAFFIC from every colour of every traffic sprite, each
## body at least MIN_BODY_TO_TRAFFIC; any two seats' bodies at least MIN_BODY_TO_BODY apart, and their dark or light
## shades MIN_SHADE_TO_SHADE. Seats are ordered so that the first ones, which every match uses, are the furthest apart:
## P1 RUBY and P2 TEAL face each other on the colour wheel.

const ViewConfig := preload("res://scripts/view/view_config.gd")
const Atlas := preload("res://scripts/view/atlas.gd")
const Config := preload("res://scripts/sim/config.gd")

const COUNT := 6
## What the colours are called, by seat (for people: the screens show P1 to P6 or BOT, and the colour itself).
const NAMES := ["RUBY", "TEAL", "LILAC", "PLUM", "BROWN", "PINK"]
## car_red's body reds: body, dark, light.
const SOURCE := [Color("#ae2633"), Color("#611732"), Color("#f26864")]
## The ranks of SOURCE and of each seat's SHADES.
const BODY := 0
const DARK := 1
const LIGHT := 2
## Per seat, the shades that replace SOURCE: body, dark, light.
const SHADES := [
	[Color("#dd0f63"), Color("#8c0848"), Color("#ff5a8c")],
	[Color("#009690"), Color("#00474c"), Color("#64cca8")],
	[Color("#b7b4fe"), Color("#9184e0"), Color("#dcd4ff")],
	[Color("#600884"), Color("#32002f"), Color("#a8309a")],
	[Color("#886000"), Color("#4a3200"), Color("#9c863c")],
	[Color("#fb99b6"), Color("#d0628f"), Color("#ffcadb")],
]
## The shades every car wears inside a tunnel (Túnel de los Gemelos, tunnel.gd): body, dark, light. A silver, the same
## for all seats, so no car stands out. Not a seat colour: the set above, its tests and the join screen do not see it.
const TWIN_SHADES := [Color("#c4c4cc"), Color("#6c6c78"), Color("#ececf4")]
## The frames that get a copy per seat: upright and turned 45 degrees each way (cars.gd player_sprite()).
const FRAMES := [ViewConfig.PLAYER, ViewConfig.PLAYER_SKID_LEFT, ViewConfig.PLAYER_SKID_RIGHT]
## The least CIEDE2000 distances the set keeps (tests/test_seat_colours.gd measures them on the frames' pixels).
const MIN_SHADE_TO_TRAFFIC := 15.0
const MIN_BODY_TO_TRAFFIC := 20.0
const MIN_BODY_TO_BODY := 20.0
const MIN_SHADE_TO_SHADE := 15.0
## Any two seats' colours of any rank, such as one seat's dark shade and another's body (the verifier's finding).
const MIN_ANY_TO_ANY := 8.0
## Text on a seat's colour (a badge) is black on light colours and white on dark ones: black from this relative
## luminance up, where black stands out at least as much as white does.
const INK_LUMINANCE := 0.18


## The seat's colour: its cars' body colour, for badges, borders and swatches.
static func colour(seat: int) -> Color:
	return SHADES[seat][BODY]


## One of the seat's shades (BODY, DARK or LIGHT).
static func shade(seat: int, rank: int) -> Color:
	return SHADES[seat][rank]


## The colour for text drawn on the seat's colour: ViewConfig.BLACK or WHITE, whichever stands out more.
static func ink(seat: int) -> Color:
	return ViewConfig.BLACK if luminance(colour(seat)) >= INK_LUMINANCE else ViewConfig.WHITE


## How a seat is named on screen: P1 to P6 for a person's, BOT for a bot's (the colour tells bots apart).
static func label(seat: int, person: bool) -> String:
	return "P%d" % (seat + 1) if person else "BOT"


## The name of a seat's copy of a frame in the atlas's frame map.
static func frame_name(frame: String, seat: int) -> String:
	return "%s@p%d" % [frame, seat + 1]


## The name of a frame's copy in the twin silver.
static func twin_frame_name(frame: String) -> String:
	return "%s@twin" % frame


## A sprite ({frame, shadow}) in the twin silver.
static func twin_sprite(spec: Dictionary) -> Dictionary:
	return {"frame": twin_frame_name(spec["frame"]), "shadow": spec["shadow"]}


## A sprite ({frame, shadow}, as view_config.gd's) in a seat's colour.
static func seat_sprite(spec: Dictionary, seat: int) -> Dictionary:
	return {"frame": frame_name(spec["frame"], seat), "shadow": spec["shadow"]}


## Adds every seat's copy of FRAMES to the atlas. False if a frame to copy is missing (the view then draws the
## seats' cars as flat rectangles in colour()).
static func add_frames(atlas: Atlas) -> bool:
	var ok := true
	for spec: Dictionary in FRAMES:
		var name: String = spec["frame"]
		var image := image_of(atlas.frame(name))
		if image == null:
			ok = false
			continue
		for seat in COUNT:
			atlas.frames[frame_name(name, seat)] = ImageTexture.create_from_image(recoloured(image, seat))
		atlas.frames[twin_frame_name(name)] = ImageTexture.create_from_image(recoloured_to(image, TWIN_SHADES))
	return ok


## A copy of an image with SOURCE's colours swapped for the seat's SHADES. Pixels are compared as bytes.
static func recoloured(image: Image, seat: int) -> Image:
	return recoloured_to(image, SHADES[seat])


## A copy of an image with SOURCE's colours swapped for `shades` (body, dark, light).
static func recoloured_to(image: Image, shades: Array) -> Image:
	var out := image.duplicate() as Image
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


## A frame's pixels as an RGBA8 image (an atlas region or a code-drawn texture), or null.
static func image_of(tex: Texture2D) -> Image:
	var image: Image = null
	var region := tex as AtlasTexture
	if region != null:
		if region.atlas == null:
			return null
		var sheet := region.atlas.get_image()
		if sheet != null:
			image = sheet.get_region(Rect2i(region.region))
	elif tex != null:
		image = tex.get_image()
	if image != null:
		image.convert(Image.FORMAT_RGBA8)
	return image


## The frames of the traffic whose colours no seat may come near: every kind's frame (ViewConfig.TRAFFIC) but the
## fuel car's, the declared exception: it is always tinted through the rainbow (cars.gd rainbow()).
static func traffic_frames() -> Array[String]:
	var out: Array[String] = []
	for kind in ViewConfig.TRAFFIC.size():
		if kind != Config.KIND_FUEL_CAR:
			out.append(ViewConfig.TRAFFIC[kind]["frame"])
	return out


## Every colour of the opaque pixels of the traffic frames (traffic_frames()), each once, as opaque colours.
static func traffic_colours(atlas: Atlas) -> Array[Color]:
	var out: Array[Color] = []
	for name: String in traffic_frames():
		var image := image_of(atlas.frame(name))
		if image == null:
			continue
		for y in image.get_height():
			for x in image.get_width():
				var pixel := image.get_pixel(x, y)
				var opaque := Color8(pixel.r8, pixel.g8, pixel.b8)
				if pixel.a8 > 0 and not out.has(opaque):
					out.append(opaque)
	return out


# --- Colour difference -----------------------------------------------------------------------------------------------


## Relative luminance of an sRGB colour (0 black to 1 white), as WCAG defines it.
static func luminance(c: Color) -> float:
	var linear := _linear(c)
	return 0.2126729 * linear[0] + 0.7151522 * linear[1] + 0.0721750 * linear[2]


## CIE L*a*b* of an sRGB colour, D65 white: [L, a, b], L from 0 to 100. In 64-bit floats throughout (a Vector3 holds
## 32-bit ones, which moves CIEDE2000's hue cases at exactly 180 degrees apart).
static func lab(c: Color) -> PackedFloat64Array:
	var linear := _linear(c)
	var x := (0.4124564 * linear[0] + 0.3575761 * linear[1] + 0.1804375 * linear[2]) / 0.95047
	var y := 0.2126729 * linear[0] + 0.7151522 * linear[1] + 0.0721750 * linear[2]
	var z := (0.0193339 * linear[0] + 0.1191920 * linear[1] + 0.9503041 * linear[2]) / 1.08883
	var fx := _lab_f(x)
	var fy := _lab_f(y)
	var fz := _lab_f(z)
	return PackedFloat64Array([116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz)])


## CIEDE2000 colour difference of two sRGB colours (about 1: just noticeable side by side; 10 and more: clearly
## different colours).
static func delta_e(a: Color, b: Color) -> float:
	return delta_e_lab(lab(a), lab(b))


## CIEDE2000 of two L*a*b* colours ([L, a, b]; Sharma, Wu and Dalal, Color Research and Application 30, 2005), with
## kL = kC = kH = 1.
static func delta_e_lab(lab1: PackedFloat64Array, lab2: PackedFloat64Array) -> float:
	var c1 := sqrt(lab1[1] * lab1[1] + lab1[2] * lab1[2])
	var c2 := sqrt(lab2[1] * lab2[1] + lab2[2] * lab2[2])
	var c_mean7 := pow((c1 + c2) / 2.0, 7.0)
	var g := 0.5 * (1.0 - sqrt(c_mean7 / (c_mean7 + pow(25.0, 7.0))))
	var a1 := (1.0 + g) * lab1[1]
	var a2 := (1.0 + g) * lab2[1]
	var cp1 := sqrt(a1 * a1 + lab1[2] * lab1[2])
	var cp2 := sqrt(a2 * a2 + lab2[2] * lab2[2])
	var hp1 := _hue_degrees(a1, lab1[2])
	var hp2 := _hue_degrees(a2, lab2[2])
	var dl := lab2[0] - lab1[0]
	var dc := cp2 - cp1
	var dh := 0.0
	if cp1 * cp2 != 0.0:
		dh = hp2 - hp1
		if dh > 180.0:
			dh -= 360.0
		elif dh < -180.0:
			dh += 360.0
	var big_dh := 2.0 * sqrt(cp1 * cp2) * sin(deg_to_rad(dh / 2.0))
	var l_mean := (lab1[0] + lab2[0]) / 2.0
	var cp_mean := (cp1 + cp2) / 2.0
	var h_mean := hp1 + hp2
	if cp1 * cp2 != 0.0:
		if absf(hp1 - hp2) <= 180.0:
			h_mean = (hp1 + hp2) / 2.0
		elif hp1 + hp2 < 360.0:
			h_mean = (hp1 + hp2 + 360.0) / 2.0
		else:
			h_mean = (hp1 + hp2 - 360.0) / 2.0
	var t := (
		1.0 - 0.17 * cos(deg_to_rad(h_mean - 30.0)) + 0.24 * cos(deg_to_rad(2.0 * h_mean))
		+ 0.32 * cos(deg_to_rad(3.0 * h_mean + 6.0)) - 0.20 * cos(deg_to_rad(4.0 * h_mean - 63.0))
	)
	var d_theta := 30.0 * exp(-pow((h_mean - 275.0) / 25.0, 2.0))
	var cp_mean7 := pow(cp_mean, 7.0)
	var rc := 2.0 * sqrt(cp_mean7 / (cp_mean7 + pow(25.0, 7.0)))
	var l50 := pow(l_mean - 50.0, 2.0)
	var sl := 1.0 + 0.015 * l50 / sqrt(20.0 + l50)
	var sc := 1.0 + 0.045 * cp_mean
	var sh := 1.0 + 0.015 * cp_mean * t
	var rt := -sin(deg_to_rad(2.0 * d_theta)) * rc
	var tl := dl / sl
	var tc := dc / sc
	var th := big_dh / sh
	return sqrt(tl * tl + tc * tc + th * th + rt * tc * th)


## The sRGB channels of a colour made linear, in 64-bit floats.
static func _linear(c: Color) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	for v: float in [c.r8 / 255.0, c.g8 / 255.0, c.b8 / 255.0]:
		out.append(v / 12.92 if v <= 0.04045 else pow((v + 0.055) / 1.055, 2.4))
	return out


static func _lab_f(t: float) -> float:
	var delta := 6.0 / 29.0
	return pow(t, 1.0 / 3.0) if t > delta * delta * delta else t / (3.0 * delta * delta) + 4.0 / 29.0


## The hue angle of (a, b) in degrees, 0 to 360; 0 for a grey.
static func _hue_degrees(a: float, b: float) -> float:
	if a == 0.0 and b == 0.0:
		return 0.0
	return fposmod(rad_to_deg(atan2(b, a)), 360.0)

