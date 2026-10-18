extends "res://tests/test_case.gd"
## The seats' colours (B2, scripts/view/player_colours.gd): six colours, one per seat; the recoloured copies of car_red
## and its 45-degree frames that boot adds to the atlas; each car drawn in its seat's colour in versus and as car_red in
## single player; the seats' names. Then the colours themselves, measured on the pixels of the frames (plan §8 B2,
## test_colour_sets_disjoint): no seat colour is a traffic colour, each stays a set CIEDE2000 distance from every
## traffic colour and from the other seats' colours, and the distance itself matches the published test data.

const PlayerColours := preload("res://scripts/view/player_colours.gd")
const Atlas := preload("res://scripts/view/atlas.gd")
const Cars := preload("res://scripts/view/cars.gd")
const ViewConfig := preload("res://scripts/view/view_config.gd")
const Car := preload("res://scripts/sim/car.gd")
const Config := preload("res://scripts/sim/config.gd")

## CIEDE2000 test data of Sharma, Wu and Dalal (2005), table 1: L1 a1 b1, L2 a2 b2, the difference.
const SHARMA := [
	[50.0, 2.6772, -79.7751, 50.0, 0.0, -82.7485, 2.0425],
	[50.0, 3.1571, -77.2803, 50.0, 0.0, -82.7485, 2.8615],
	[50.0, 2.8361, -74.0200, 50.0, 0.0, -82.7485, 3.4412],
	[50.0, -1.3802, -84.2814, 50.0, 0.0, -82.7485, 1.0],
	[50.0, -1.1848, -84.8006, 50.0, 0.0, -82.7485, 1.0],
	[50.0, -0.9009, -85.5211, 50.0, 0.0, -82.7485, 1.0],
	[50.0, 0.0, 0.0, 50.0, -1.0, 2.0, 2.3669],
	[50.0, -1.0, 2.0, 50.0, 0.0, 0.0, 2.3669],
	[50.0, 2.49, -0.001, 50.0, -2.49, 0.0009, 7.1792],
	[50.0, 2.49, -0.001, 50.0, -2.49, 0.001, 7.1792],
	[50.0, 2.49, -0.001, 50.0, -2.49, 0.0011, 7.2195],
	[50.0, 2.49, -0.001, 50.0, -2.49, 0.0012, 7.2195],
	[50.0, -0.001, 2.49, 50.0, 0.0009, -2.49, 4.8045],
	[50.0, -0.001, 2.49, 50.0, 0.001, -2.49, 4.8045],
	[50.0, -0.001, 2.49, 50.0, 0.0011, -2.49, 4.7461],
	[50.0, 2.5, 0.0, 50.0, 0.0, -2.5, 4.3065],
	[50.0, 2.5, 0.0, 73.0, 25.0, -18.0, 27.1492],
	[50.0, 2.5, 0.0, 61.0, -5.0, 29.0, 22.8977],
	[50.0, 2.5, 0.0, 56.0, -27.0, -3.0, 31.903],
	[50.0, 2.5, 0.0, 58.0, 24.0, 15.0, 19.4535],
	[50.0, 2.5, 0.0, 50.0, 3.1736, 0.5854, 1.0],
	[50.0, 2.5, 0.0, 50.0, 3.2972, 0.0, 1.0],
	[50.0, 2.5, 0.0, 50.0, 1.8634, 0.5757, 1.0],
	[50.0, 2.5, 0.0, 50.0, 3.2592, 0.335, 1.0],
	[60.2574, -34.0099, 36.2677, 60.4626, -34.1751, 39.4387, 1.2644],
	[63.0109, -31.0961, -5.8663, 62.8187, -29.7946, -4.0864, 1.263],
	[61.2901, 3.7196, -5.3901, 61.4292, 2.248, -4.962, 1.8731],
	[35.0831, -44.1164, 3.7933, 35.0232, -40.0716, 1.5901, 1.8645],
	[22.7233, 20.0904, -46.694, 23.0331, 14.973, -42.5619, 2.0373],
	[36.4612, 47.858, 18.3852, 36.2715, 50.5065, 21.2231, 1.4146],
	[90.8027, -2.0831, 1.441, 91.1528, -1.6435, 0.0447, 1.4441],
	[90.9257, -0.5406, -0.9208, 88.6381, -0.8985, -0.7239, 1.5381],
	[6.7747, -0.2908, -2.4247, 5.8714, -0.0985, -2.2286, 0.6377],
	[2.0776, 0.0795, -1.135, 0.9033, -0.0636, -0.5514, 0.9082],
]

var atlas: Atlas


func before_all() -> void:
	atlas = Atlas.new()
	atlas.load_all()
	PlayerColours.add_frames(atlas)


func test_six_seats_six_different_colours() -> void:
	assert_eq(PlayerColours.COUNT, Config.VERSUS_SEATS_MAX)
	assert_eq(PlayerColours.SHADES.size(), PlayerColours.COUNT)
	assert_eq(PlayerColours.NAMES.size(), PlayerColours.COUNT)
	var seen: Array = []
	for seat in PlayerColours.COUNT:
		assert_eq(PlayerColours.colour(seat), PlayerColours.shade(seat, PlayerColours.BODY))
		assert_eq((PlayerColours.SHADES[seat] as Array).size(), PlayerColours.SOURCE.size())
		for rank in PlayerColours.SOURCE.size():
			var html := PlayerColours.shade(seat, rank).to_html(false)
			assert_false(seen.has(html), "seat %d's shade %d is its own" % [seat, rank])
			seen.append(html)
	assert_eq(seen.size(), 18)


## Boot adds each seat's copy of car_red and its two 45-degree frames: the same size, every one of car_red's body reds
## swapped for the seat's shade of the same rank, every other pixel as it was.
func test_every_seat_gets_recoloured_copies_of_the_three_frames() -> void:
	var fresh := Atlas.new()
	fresh.load_all()
	var before := fresh.frames.size()
	assert_true(PlayerColours.add_frames(fresh))
	assert_eq(fresh.frames.size(), before + PlayerColours.FRAMES.size() * PlayerColours.COUNT)
	var sheet := fresh.texture.get_image()
	sheet.convert(Image.FORMAT_RGBA8)
	for spec: Dictionary in PlayerColours.FRAMES:
		var name: String = spec["frame"]
		var region := Rect2i((fresh.frame(name) as AtlasTexture).region)
		var source := sheet.get_region(region)
		for seat in PlayerColours.COUNT:
			var copy := fresh.frame(PlayerColours.frame_name(name, seat))
			assert_not_null(copy, "%s for seat %d" % [name, seat])
			if copy == null:
				continue
			var image := copy.get_image()
			image.convert(Image.FORMAT_RGBA8)
			assert_eq(image.get_size(), region.size)
			var shades: Array = PlayerColours.SHADES[seat]
			var wrong := 0
			var swapped := 0
			for y in region.size.y:
				for x in region.size.x:
					var was := source.get_pixel(x, y)
					var now := image.get_pixel(x, y)
					var expected := was
					for i in PlayerColours.SOURCE.size():
						if was.a8 > 0 and _same_rgb(was, PlayerColours.SOURCE[i]):
							expected = Color(shades[i], was.a)
							swapped += 1
					if not _same_rgb(now, expected) or now.a8 != was.a8:
						wrong += 1
			assert_eq(wrong, 0, "%s for seat %d" % [name, seat])
			assert_gt(swapped, 20, "%s has body pixels to recolour" % name)


## Plan §8 B2: the players' colours and the traffic's are two sets with nothing in common. Both are read from the
## pixels: a seat's colours are those of its three frames where car_red has its body reds (and they are exactly its
## three shades, the body the commonest); the traffic's are every colour of the yellow, salmon and blue cars, the
## truck and the oil (the fuel car, tinted through the rainbow, is the declared exception). No two seats share one
## either.
func test_colour_sets_disjoint() -> void:
	var traffic := PlayerColours.traffic_colours(atlas)
	assert_false(PlayerColours.traffic_frames().has(ViewConfig.TRAFFIC[Config.KIND_FUEL_CAR]["frame"]), "the fuel car is the exception")
	assert_eq(PlayerColours.traffic_frames().size(), Config.KIND_COUNT - 1)
	for known: String in ["#f1bb3b", "#d4705c", "#1f95e1", "#42ad37", "#f0eeec", "#141414"]:
		assert_true(traffic.has(Color(known)), "the traffic's colours include %s" % known)
	var taken := {}
	for seat in PlayerColours.COUNT:
		var counts := seat_colour_counts(atlas, seat)
		var colours: Array = counts.keys()
		var expected: Array = []
		for rank in PlayerColours.SOURCE.size():
			expected.append(PlayerColours.shade(seat, rank).to_html(false))
		colours.sort()
		expected.sort()
		assert_eq(colours, expected, "seat %d's frames carry its three shades" % seat)
		assert_eq(commonest(counts), PlayerColours.colour(seat).to_html(false), "seat %d's body is its commonest" % seat)
		for html: String in counts:
			assert_false(traffic.has(Color(html)), "seat %d's %s is a traffic colour" % [seat, html])
			assert_false(taken.has(html), "seat %d's %s is seat %s's too" % [seat, html, taken.get(html)])
			taken[html] = seat
	assert_eq(taken.size(), 18)


## Every colour of every seat's car is at least MIN_SHADE_TO_TRAFFIC (CIEDE2000) from every traffic colour, and each
## body, the colour that covers most of the car, at least MIN_BODY_TO_TRAFFIC, measured on the frames' pixels.
func test_player_colours_are_far_from_traffic() -> void:
	var traffic := PlayerColours.traffic_colours(atlas)
	assert_eq(traffic.size(), 18, "the traffic's colours: 6 of the yellow car, 5 more of the salmon one, 3 of the blue one, 4 of the truck")
	var nearest_shade := INF
	var nearest_body := INF
	for seat in PlayerColours.COUNT:
		var counts := seat_colour_counts(atlas, seat)
		for html: String in counts:
			var d := nearest(Color(html), traffic)
			var what := "seat %d (%s) %s is %.1f from %s" % [seat, PlayerColours.NAMES[seat], html, d["distance"], d["colour"]]
			assert_gt(d["distance"], PlayerColours.MIN_SHADE_TO_TRAFFIC, what)
			nearest_shade = minf(nearest_shade, d["distance"])
			if html == commonest(counts):
				assert_gt(d["distance"], PlayerColours.MIN_BODY_TO_TRAFFIC, "body: " + what)
				nearest_body = minf(nearest_body, d["distance"])
	assert_lt(nearest_shade, INF)
	assert_lt(nearest_body, INF)


## The seats' colours are far from each other too: any two bodies at least MIN_BODY_TO_BODY, any two dark or light
## shades at least MIN_SHADE_TO_SHADE.
func test_player_colours_are_far_from_each_other() -> void:
	for a in PlayerColours.COUNT:
		for b in range(a + 1, PlayerColours.COUNT):
			for rank in PlayerColours.SOURCE.size():
				var least := PlayerColours.MIN_BODY_TO_BODY if rank == PlayerColours.BODY else PlayerColours.MIN_SHADE_TO_SHADE
				var d := PlayerColours.delta_e(PlayerColours.shade(a, rank), PlayerColours.shade(b, rank))
				assert_gt(d, least, "%s and %s, shade %d: %.1f" % [PlayerColours.NAMES[a], PlayerColours.NAMES[b], rank, d])


## Shades of different ranks too: any colour of one seat at least MIN_ANY_TO_ANY from any colour of another.
func test_player_shades_of_any_rank_are_far_from_each_other() -> void:
	for a in PlayerColours.COUNT:
		for b in range(a + 1, PlayerColours.COUNT):
			for ra in PlayerColours.SOURCE.size():
				for rb in PlayerColours.SOURCE.size():
					var d := PlayerColours.delta_e(PlayerColours.shade(a, ra), PlayerColours.shade(b, rb))
					assert_gt(d, PlayerColours.MIN_ANY_TO_ANY, "%s shade %d and %s shade %d: %.1f" % [PlayerColours.NAMES[a], ra, PlayerColours.NAMES[b], rb, d])


## The distance is CIEDE2000: the 34 pairs of its published test data, and sRGB to L*a*b* (D65) for the primaries.
func test_delta_e_matches_the_published_test_data() -> void:
	var worst := 0.0
	for pair: Array in SHARMA:
		var first := PackedFloat64Array([pair[0], pair[1], pair[2]])
		var second := PackedFloat64Array([pair[3], pair[4], pair[5]])
		var got := PlayerColours.delta_e_lab(first, second)
		var back := PlayerColours.delta_e_lab(second, first)
		assert_almost_eq(got, float(pair[6]), 0.0001, "pair %s" % [pair])
		assert_almost_eq(back, got, 0.000001, "symmetric")
		worst = maxf(worst, absf(got - float(pair[6])))
	assert_lt(worst, 0.0001)
	var primaries := {
		"#ffffff": [100.0, 0.0, 0.0], "#ff0000": [53.24, 80.09, 67.2], "#00ff00": [87.73, -86.18, 83.18],
		"#0000ff": [32.3, 79.19, -107.86], "#000000": [0.0, 0.0, 0.0],
	}
	for html: String in primaries:
		var got := PlayerColours.lab(Color(html))
		var want: Array = primaries[html]
		for i in 3:
			assert_almost_eq(got[i], want[i], 0.02, "%s component %d" % [html, i])
	assert_eq(PlayerColours.delta_e(Color("#dd0f63"), Color("#dd0f63")), 0.0)


## The ink of a badge (black or white) stands out on the seat's colour at least as well as the other would, and
## well enough for text (a WCAG contrast of 3 or more).
func test_badge_ink_stands_out_on_every_seat_colour() -> void:
	for seat in PlayerColours.COUNT:
		var back := PlayerColours.colour(seat)
		var ink := PlayerColours.ink(seat)
		var other := ViewConfig.WHITE if ink == ViewConfig.BLACK else ViewConfig.BLACK
		assert_true(ink == ViewConfig.BLACK or ink == ViewConfig.WHITE)
		assert_gt(contrast(ink, back), contrast(other, back) - 0.0001, "seat %d" % seat)
		assert_gt(contrast(ink, back), 3.0, "seat %d" % seat)


func test_each_car_is_drawn_in_its_seats_colour_in_versus_only() -> void:
	var car := Car.new()
	var none: Array[int] = []
	assert_eq(Cars.seat_car_sprite(car, none), ViewConfig.PLAYER, "single player: car_red")
	car.slot = 1
	var lineup: Array[int] = [3, 5]
	assert_eq(Cars.seat_car_sprite(car, lineup)["frame"], PlayerColours.frame_name("car_red", 5))
	car.slide_vx = 10.0
	assert_eq(Cars.seat_car_sprite(car, lineup)["frame"], PlayerColours.frame_name("car_red_cw45", 5))
	car.slide_vx = -10.0
	assert_eq(Cars.seat_car_sprite(car, lineup)["frame"], PlayerColours.frame_name("car_red_ccw45", 5))
	assert_eq(Cars.seat_car_sprite(car, lineup)["shadow"], ViewConfig.PLAYER_SKID_LEFT["shadow"])


func test_seats_are_named_p1_to_p6_or_bot() -> void:
	assert_eq([PlayerColours.label(0, true), PlayerColours.label(5, true), PlayerColours.label(3, false)], ["P1", "P6", "BOT"])


# --- helpers ---------------------------------------------------------------------------------------------------------


## The colours of a seat's three frames where car_red has its body reds: html -> pixel count.
static func seat_colour_counts(p_atlas: Atlas, seat: int) -> Dictionary:
	var counts := {}
	for spec: Dictionary in PlayerColours.FRAMES:
		var name: String = spec["frame"]
		var source := PlayerColours.image_of(p_atlas.frame(name))
		var copy := PlayerColours.image_of(p_atlas.frame(PlayerColours.frame_name(name, seat)))
		if source == null or copy == null:
			continue
		for y in source.get_height():
			for x in source.get_width():
				var was := source.get_pixel(x, y)
				var is_body := false
				for red: Color in PlayerColours.SOURCE:
					is_body = is_body or (was.a8 > 0 and _same_rgb(was, red))
				if is_body:
					var html := copy.get_pixel(x, y).to_html(false)
					counts[html] = int(counts.get(html, 0)) + 1
	return counts


static func commonest(counts: Dictionary) -> String:
	var best := ""
	for html: String in counts:
		if best.is_empty() or counts[html] > counts[best]:
			best = html
	return best


## The traffic colour nearest a colour: {distance, colour (html)}.
static func nearest(c: Color, traffic: Array[Color]) -> Dictionary:
	var best := {"distance": INF, "colour": ""}
	for t: Color in traffic:
		var d := PlayerColours.delta_e(c, t)
		if d < best["distance"]:
			best = {"distance": d, "colour": t.to_html(false)}
	return best


## WCAG contrast ratio of two colours.
static func contrast(a: Color, b: Color) -> float:
	var la := PlayerColours.luminance(a)
	var lb := PlayerColours.luminance(b)
	return (maxf(la, lb) + 0.05) / (minf(la, lb) + 0.05)


static func _same_rgb(a: Color, b: Color) -> bool:
	return a.r8 == b.r8 and a.g8 == b.g8 and a.b8 == b.b8
