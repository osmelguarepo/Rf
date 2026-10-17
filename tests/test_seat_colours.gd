extends "res://tests/test_case.gd"
## The seats' colours as the view uses them (B2, scripts/view/player_colours.gd): six colours, one per seat; the
## recoloured copies of car_red and its 45-degree frames that boot adds to the atlas; each car drawn in its seat's
## colour in versus and as car_red in single player; the seats' names. The final six colours and their distance from
## the traffic's (test_colour_sets_disjoint, plan §8 B2) are B2b's.

const PlayerColours := preload("res://scripts/view/player_colours.gd")
const Atlas := preload("res://scripts/view/atlas.gd")
const Cars := preload("res://scripts/view/cars.gd")
const ViewConfig := preload("res://scripts/view/view_config.gd")
const Car := preload("res://scripts/sim/car.gd")
const Config := preload("res://scripts/sim/config.gd")

var atlas: Atlas


func before_all() -> void:
	atlas = Atlas.new()
	atlas.load_all()


func test_six_seats_six_different_colours() -> void:
	assert_eq(PlayerColours.COUNT, Config.VERSUS_SEATS_MAX)
	assert_eq(PlayerColours.SHADES.size(), PlayerColours.COUNT)
	assert_eq(PlayerColours.NAMES.size(), PlayerColours.COUNT)
	var seen: Array = []
	for seat in PlayerColours.COUNT:
		var colour := PlayerColours.colour(seat)
		assert_false(seen.has(colour.to_html()), "seat %d's colour is its own" % seat)
		seen.append(colour.to_html())
		assert_eq((PlayerColours.SHADES[seat] as Array).size(), PlayerColours.SOURCE.size())
	assert_eq(PlayerColours.SHADES[0], PlayerColours.SOURCE, "seat 0 keeps car_red's reds")


## Boot adds each seat's copy of car_red and its two 45-degree frames: the same size, every one of car_red's body reds
## swapped for the seat's shade of the same rank, every other pixel as it was.
func test_every_seat_gets_recoloured_copies_of_the_three_frames() -> void:
	var before := atlas.frames.size()
	assert_true(PlayerColours.add_frames(atlas))
	assert_eq(atlas.frames.size(), before + PlayerColours.FRAMES.size() * PlayerColours.COUNT)
	var sheet := atlas.texture.get_image()
	sheet.convert(Image.FORMAT_RGBA8)
	for spec: Dictionary in PlayerColours.FRAMES:
		var name: String = spec["frame"]
		var region := Rect2i((atlas.frame(name) as AtlasTexture).region)
		var source := sheet.get_region(region)
		for seat in PlayerColours.COUNT:
			var copy := atlas.frame(PlayerColours.frame_name(name, seat))
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


static func _same_rgb(a: Color, b: Color) -> bool:
	return a.r8 == b.r8 and a.g8 == b.g8 and a.b8 == b.b8
