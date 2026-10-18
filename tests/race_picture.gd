extends RefCounted
## The versus race picture (docs/screenshots/08-versus-race.png, made by tools/screenshots.gd) checked by its pixels
## alone (B2; plan §8 B2: six cars of six colours that match no traffic colour, checked by sampling the picture's
## pixels). Not a test file: tests/test_versus_look.gd runs check() on the committed picture (and on spoilt copies of
## it, which must fail), and tools/screenshots.gd on the file it has just saved, so neither can keep a picture that
## fails.
##
## It knows nothing of the world the picture shows: it finds sprites by their pixels. A sprite is found where a frame,
## drawn at ViewConfig.SPRITE_SCALE, has every opaque pixel in the picture exactly (find_sprites()). It checks that:
##   1. the picture is the 640x360 viewport at PICTURE_SCALE with Nearest: every 2x2 block is one colour;
##   2. each seat's car, its copy of car_red or of a 45-degree frame (player_colours.gd), is on the road once;
##   3. each kind of traffic car (TRAFFIC_KINDS: yellow, salmon, blue, truck) is on the road at least once;
##   4. the colours sampled where each car has car_red's body reds are its seat's three shades, the body (the
##      commonest) among them, 18 colours in all; none of them is a colour sampled on the traffic sprites; each is at
##      least PlayerColours.MIN_SHADE_TO_TRAFFIC (CIEDE2000) from every one of those and each body
##      MIN_BODY_TO_TRAFFIC; and the six sampled bodies are at least MIN_BODY_TO_BODY apart;
##   5. no other pixel of the road and its verges (ROAD) has a player colour;
##   6. each seat's HUD panel (versus_hud.gd seat_panel_rect()) has a border of its seat's colour.
## The fuel car is the declared exception (tinted through the rainbow), and the picture need not show it.

const PlayerColours := preload("res://scripts/view/player_colours.gd")
const ViewConfig := preload("res://scripts/view/view_config.gd")
const VersusHud := preload("res://scripts/view/versus_hud.gd")
const Atlas := preload("res://scripts/view/atlas.gd")
const Config := preload("res://scripts/sim/config.gd")

const PATH := "res://docs/screenshots/08-versus-race.png"
## The screenshots are the viewport at 2x (tools/screenshots.gd SCALE).
const PICTURE_SCALE := 2
## The road and its verges, where the cars and the traffic are (x 168 to 472, tests/test_versus_look.gd); the seat
## panels stay outside it.
const ROAD := Rect2i(168, 0, 304, ViewConfig.VIEW_H)
## The kinds of traffic the picture must show, so the cars' colours are compared with theirs on the same picture.
const TRAFFIC_KINDS: Array[int] = [Config.KIND_YELLOW, Config.KIND_RED, Config.KIND_BLUE, Config.KIND_TRUCK]


## The PNG at a path (res:// or absolute), read as bytes (plan §2: never Image.load_from_file on res://), as RGB8; or
## null.
static func load_png(path: String) -> Image:
	var bytes := FileAccess.get_file_as_bytes(path)
	var image := Image.new()
	if bytes.is_empty() or image.load_png_from_buffer(bytes) != OK:
		return null
	image.convert(Image.FORMAT_RGB8)
	return image


## The viewport the picture shows (1x, RGB8): null unless the picture is VIEW_W x VIEW_H at PICTURE_SCALE with every
## PICTURE_SCALE-square block one colour.
static func viewport_of(picture: Image) -> Image:
	if picture == null or picture.get_size() != Vector2i(ViewConfig.VIEW_W, ViewConfig.VIEW_H) * PICTURE_SCALE:
		return null
	var full := picture.duplicate() as Image
	full.convert(Image.FORMAT_RGB8)
	var small := full.duplicate() as Image
	small.resize(ViewConfig.VIEW_W, ViewConfig.VIEW_H, Image.INTERPOLATE_NEAREST)
	var again := small.duplicate() as Image
	again.resize(full.get_width(), full.get_height(), Image.INTERPOLATE_NEAREST)
	return small if again.get_data() == full.get_data() else null


## What the searches read: {pixels (the viewport as 0xRRGGBB, row by row), where (rgb -> the indexes of its pixels on
## ROAD)}; {} unless the picture passes viewport_of().
static func scan(picture: Image) -> Dictionary:
	var view := viewport_of(picture)
	if view == null:
		return {}
	var data := view.get_data()
	var pixels := PackedInt32Array()
	pixels.resize(ViewConfig.VIEW_W * ViewConfig.VIEW_H)
	for i in pixels.size():
		pixels[i] = (data[i * 3] << 16) | (data[i * 3 + 1] << 8) | data[i * 3 + 2]
	var where := {}
	for y in range(ROAD.position.y, ROAD.end.y):
		for x in range(ROAD.position.x, ROAD.end.x):
			var i := y * ViewConfig.VIEW_W + x
			if where.has(pixels[i]):
				(where[pixels[i]] as Array).append(i)
			else:
				where[pixels[i]] = [i]
	return {"pixels": pixels, "where": where}


## Each seat's car on the road: seat -> an Array of {at (top-left corner), source (the car_red frame it is a copy
## of)}, one per sprite found. The atlas must have the seats' frames (PlayerColours.add_frames()).
static func find_cars(scanned: Dictionary, atlas: Atlas) -> Dictionary:
	var out := {}
	for seat in PlayerColours.COUNT:
		var found: Array[Dictionary] = []
		for spec: Dictionary in PlayerColours.FRAMES:
			var source: String = spec["frame"]
			for at: Vector2i in find_sprites(scanned, frame_pixels(atlas, PlayerColours.frame_name(source, seat))):
				found.append({"at": at, "source": source})
		out[seat] = found
	return out


## Each kind of TRAFFIC_KINDS on the road: kind -> the top-left corners of its sprites.
static func find_traffic(scanned: Dictionary, atlas: Atlas) -> Dictionary:
	var out := {}
	for kind: int in TRAFFIC_KINDS:
		out[kind] = find_sprites(scanned, frame_pixels(atlas, ViewConfig.TRAFFIC[kind]["frame"]))
	return out


## Checks a race picture (see the top of the file). The atlas must have the seats' frames
## (PlayerColours.add_frames()). Returns {problems (empty when all is well), cars (seats whose car is on the road
## once), traffic (kind -> sprites found), nearest_shade and nearest_body (the least CIEDE2000 distances between the
## cars' and the traffic's sampled colours), colours (the cars' sampled colours, html)}.
static func check(picture: Image, atlas: Atlas) -> Dictionary:
	var problems := PackedStringArray()
	var result := {"problems": problems, "cars": 0, "traffic": {}, "nearest_shade": INF, "nearest_body": INF, "colours": []}
	var scanned := scan(picture)
	if scanned.is_empty():
		problems.append("the picture is not the %dx%d viewport at %dx, each block one colour" % [ViewConfig.VIEW_W, ViewConfig.VIEW_H, PICTURE_SCALE])
		return result
	var pixels: PackedInt32Array = scanned["pixels"]
	var where: Dictionary = scanned["where"]
	# 2. Each seat's car, once; the colours where car_red has its body reds, sampled.
	var car_rects: Array[Rect2i] = []
	var sampled := {}
	var cars := find_cars(scanned, atlas)
	for seat: int in cars:
		var found: Array[Dictionary] = cars[seat]
		if found.size() != 1:
			problems.append("seat %d (%s): its car is on the road %d times, not once" % [seat, PlayerColours.NAMES[seat], found.size()])
			continue
		var at: Vector2i = found[0]["at"]
		var source: String = found[0]["source"]
		car_rects.append(Rect2i(at, atlas.frame_size(source) * ViewConfig.SPRITE_SCALE))
		sampled[seat] = body_colours(pixels, at, frame_pixels(atlas, source))
		result["cars"] += 1
	# 3. The traffic, sampled: rgb -> the kind it was seen on.
	var traffic_colours := {}
	var traffic := find_traffic(scanned, atlas)
	for kind: int in traffic:
		var sprites: Array[Vector2i] = traffic[kind]
		result["traffic"][kind] = sprites.size()
		if sprites.is_empty():
			problems.append("no %s on the road to compare the cars' colours with" % Config.KIND_NAMES[kind])
		var frame := frame_pixels(atlas, ViewConfig.TRAFFIC[kind]["frame"])
		for at: Vector2i in sprites:
			for c: int in sprite_colours(pixels, at, frame):
				traffic_colours[c] = kind
	# 4. The cars' colours against their seats' shades, the traffic's colours and each other.
	var seen := {}
	var bodies := {}
	for seat: int in sampled:
		var counts: Dictionary = sampled[seat]
		var shades := {}
		for rank in PlayerColours.SOURCE.size():
			shades[to_rgb(PlayerColours.shade(seat, rank))] = rank
		var body := commonest(counts)
		bodies[seat] = body
		if counts.size() != shades.size() or not counts.keys().all(func(c: int) -> bool: return shades.has(c)):
			problems.append("seat %d's car shows %s, not its shades %s" % [seat, htmls(counts.keys()), htmls(shades.keys())])
		elif shades[body] != PlayerColours.BODY:
			problems.append("seat %d's car is mostly %s, not its body colour" % [seat, html(body)])
		for c: int in counts:
			if seen.has(c):
				problems.append("seats %d and %d's cars share %s" % [seen[c], seat, html(c)])
			seen[c] = seat
			if traffic_colours.has(c):
				problems.append("seat %d's %s is on a %s too" % [seat, html(c), Config.KIND_NAMES[traffic_colours[c]]])
			var least := PlayerColours.MIN_BODY_TO_TRAFFIC if c == body else PlayerColours.MIN_SHADE_TO_TRAFFIC
			for t: int in traffic_colours:
				var d := PlayerColours.delta_e(from_rgb(c), from_rgb(t))
				result["nearest_shade"] = minf(result["nearest_shade"], d)
				if c == body:
					result["nearest_body"] = minf(result["nearest_body"], d)
				if d < least:
					problems.append("seat %d's %s is %.1f from the %s's %s, under %.0f" % [seat, html(c), d, Config.KIND_NAMES[traffic_colours[t]], html(t), least])
	var seats: Array = bodies.keys()
	for i in seats.size():
		for j in range(i + 1, seats.size()):
			var d := PlayerColours.delta_e(from_rgb(bodies[seats[i]]), from_rgb(bodies[seats[j]]))
			if d < PlayerColours.MIN_BODY_TO_BODY:
				problems.append("seats %d and %d's bodies are %.1f apart, under %.0f" % [seats[i], seats[j], d, PlayerColours.MIN_BODY_TO_BODY])
	result["colours"] = htmls(seen.keys())
	# 5. No player colour on the road away from the cars.
	var player_colours := seen.duplicate()
	for seat in PlayerColours.COUNT:
		for rank in PlayerColours.SOURCE.size():
			player_colours[to_rgb(PlayerColours.shade(seat, rank))] = seat
	for c: int in player_colours:
		var stray := 0
		for i: int in where.get(c, []):
			var p := _point(i)
			if not car_rects.any(func(r: Rect2i) -> bool: return r.has_point(p)):
				stray += 1
		if stray > 0:
			problems.append("%d px of the road away from the cars have seat %d's %s" % [stray, player_colours[c], html(c)])
	# 6. The HUD: a panel per seat, its border in the seat's colour.
	for seat in PlayerColours.COUNT:
		var r := VersusHud.seat_panel_rect(seat)
		var border := to_rgb(PlayerColours.colour(seat))
		for p: Vector2i in [r.position + Vector2i(r.size.x >> 1, 0), r.position + Vector2i(0, r.size.y >> 1), r.end - Vector2i.ONE]:
			var c := _pixel(pixels, p)
			if c != border:
				problems.append("seat %d's HUD panel has %s at %s, not its colour %s" % [seat, html(c), p, html(border)])
	return result


## A frame's opaque pixels as [x, y, rgb] triples, in reading order; empty if the atlas lacks it.
static func frame_pixels(atlas: Atlas, name: String) -> Array:
	var out: Array = []
	var image := PlayerColours.image_of(atlas.frame(name))
	if image == null:
		return out
	for y in image.get_height():
		for x in image.get_width():
			var p := image.get_pixel(x, y)
			if p.a8 > 0:
				out.append([x, y, to_rgb(p)])
	return out


## Where a frame is drawn at ViewConfig.SPRITE_SCALE, every opaque pixel exact: the top-left corners, in viewport
## pixels. The candidates are the places on the road of the frame's colour that is rarest there, each lined up with
## the frame's first pixel of that colour.
static func find_sprites(scanned: Dictionary, frame: Array) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var where: Dictionary = scanned["where"]
	var anchor: Array = []
	for p: Array in frame:
		if anchor.is_empty() or (where.get(p[2], []) as Array).size() < (where.get(anchor[2], []) as Array).size():
			anchor = p
	if anchor.is_empty():
		return out
	for i: int in where.get(anchor[2], []):
		var at := _point(i) - Vector2i(anchor[0], anchor[1]) * ViewConfig.SPRITE_SCALE
		if _matches(scanned["pixels"], at, frame):
			out.append(at)
	return out


## The colours a found sprite shows where its frame has car_red's body reds (each frame pixel's block sampled):
## rgb -> count. Only car_red's frames have those reds, so for a seat's car these are the seat's shades.
static func body_colours(pixels: PackedInt32Array, at: Vector2i, source_frame: Array) -> Dictionary:
	var reds := {}
	for c: Color in PlayerColours.SOURCE:
		reds[to_rgb(c)] = true
	var out := {}
	for p: Array in source_frame:
		if reds.has(p[2]):
			var c := _pixel(pixels, at + Vector2i(p[0], p[1]) * ViewConfig.SPRITE_SCALE)
			out[c] = int(out.get(c, 0)) + 1
	return out


## Every colour a found sprite shows on its frame's opaque pixels: rgb -> count.
static func sprite_colours(pixels: PackedInt32Array, at: Vector2i, frame: Array) -> Dictionary:
	var out := {}
	for p: Array in frame:
		var c := _pixel(pixels, at + Vector2i(p[0], p[1]) * ViewConfig.SPRITE_SCALE)
		out[c] = int(out.get(c, 0)) + 1
	return out


## The key with the highest count (the first of equals); -1 for none.
static func commonest(counts: Dictionary) -> int:
	var best := -1
	for c: int in counts:
		if best < 0 or counts[c] > counts[best]:
			best = c
	return best


static func to_rgb(c: Color) -> int:
	return (c.r8 << 16) | (c.g8 << 8) | c.b8


static func from_rgb(rgb: int) -> Color:
	return Color8((rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff)


static func html(rgb: int) -> String:
	return "#" + from_rgb(rgb).to_html(false)


static func htmls(rgbs: Array) -> Array[String]:
	var out: Array[String] = []
	for c: int in rgbs:
		out.append(html(c))
	out.sort()
	return out


static func _matches(pixels: PackedInt32Array, at: Vector2i, frame: Array) -> bool:
	var scale := ViewConfig.SPRITE_SCALE
	if at.x < 0 or at.y < 0:
		return false
	for p: Array in frame:
		for dy in scale:
			for dx in scale:
				var x: int = at.x + p[0] * scale + dx
				var y: int = at.y + p[1] * scale + dy
				if x >= ViewConfig.VIEW_W or y >= ViewConfig.VIEW_H or pixels[y * ViewConfig.VIEW_W + x] != p[2]:
					return false
	return true


static func _pixel(pixels: PackedInt32Array, p: Vector2i) -> int:
	return pixels[p.y * ViewConfig.VIEW_W + p.x]


## The viewport pixel of an index of the scan's pixels.
static func _point(i: int) -> Vector2i:
	return Vector2i(i % ViewConfig.VIEW_W, floori(i / float(ViewConfig.VIEW_W)))
