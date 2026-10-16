extends Node2D
## The scrolling road (drawBackdrop in src/render/draw.ts, Phaser version): grass, verges, the edge tiles whose white
## line is the barrier, asphalt, the lane dashes between the six lanes and roadside bushes. Everything scrolls down as
## the road is travelled.
##
## The road is a fixed object at world y = 0: set_scroll() takes the camera's world y rounded to a whole pixel
## (cars.gd rounds it the same way), so oil patches and the road move together without a pixel of drift.

const ViewConfig := preload("res://scripts/view/view_config.gd")
const Atlas := preload("res://scripts/view/atlas.gd")
const Draw := preload("res://scripts/view/draw.gd")
const Config := preload("res://scripts/sim/config.gd")

var atlas: Atlas
var cfg: Config
## Whole pixels of road travelled.
var scroll: int = 0
## When false, the bushes go in the middle of the grass instead of beside the HUD panels (the title screen).
var beside_panels: bool = true
var _columns: Array[Dictionary] = []


func setup(p_atlas: Atlas, p_cfg: Config) -> void:
	atlas = p_atlas
	cfg = p_cfg
	_columns = columns(cfg)
	queue_redraw()


func set_scroll(travelled: int) -> void:
	if travelled != scroll:
		scroll = travelled
		queue_redraw()


## x of the left edge tile: its white line (column EDGE_LINE_LEFT) is the barrier just left of the road.
static func edge_left_x(c: Config) -> int:
	return int(c.road_left) - ViewConfig.BARRIER_W - ViewConfig.EDGE_LINE_LEFT * ViewConfig.TILE_SCALE


## x of the right edge tile: its white line (column EDGE_LINE_RIGHT) starts on the road's right edge.
static func edge_right_x(c: Config) -> int:
	return int(c.road_right) - ViewConfig.EDGE_LINE_RIGHT * ViewConfig.TILE_SCALE


## One row of tiles, left to right: {x, frame}, where frame "" is grass (its tile varies by row).
static func columns(c: Config) -> Array[Dictionary]:
	var tile := ViewConfig.TILE
	var edge_left := edge_left_x(c)
	var edge_right := edge_right_x(c)
	var verge_left := edge_left - tile
	var verge_right := edge_right + tile
	var out: Array[Dictionary] = []
	var x := verge_left - tile
	while x > -tile:
		out.append({"x": x, "frame": ""})
		x -= tile
	out.append({"x": verge_left, "frame": ViewConfig.ROAD_VERGE_LEFT})
	x = edge_left + tile
	while x < edge_right:
		out.append({"x": x, "frame": ViewConfig.ROAD_ASPHALT})
		x += tile
	out.append({"x": edge_left, "frame": ViewConfig.ROAD_EDGE_LEFT})
	out.append({"x": edge_right, "frame": ViewConfig.ROAD_EDGE_RIGHT})
	out.append({"x": verge_right, "frame": ViewConfig.ROAD_VERGE_RIGHT})
	x = verge_right + tile
	while x < ViewConfig.VIEW_W:
		out.append({"x": x, "frame": ""})
		x += tile
	return out


## Grass from the screen's edge to the end of the verge's grass columns, on each side: [left end x, right start x].
static func grass_ends(c: Config) -> Vector2i:
	var verge_left := edge_left_x(c) - ViewConfig.TILE
	var grass := ViewConfig.VERGE_GRASS_COLUMNS * ViewConfig.TILE_SCALE
	return Vector2i(verge_left + grass, ViewConfig.VIEW_W - (verge_left + grass))


## x of the left and right bushes: centred in the grass between the HUD panels and the verges, or in the whole
## grass strip when there are no panels.
static func bush_x(c: Config, p_beside_panels: bool, bush_w: int) -> Vector2i:
	var ends := grass_ends(c)
	var left_from := ViewConfig.PANEL_LEFT.end.x if p_beside_panels else 0
	var right_to := ViewConfig.PANEL_RIGHT.position.x if p_beside_panels else ViewConfig.VIEW_W
	return Vector2i(
		left_from + floori((ends.x - left_from - bush_w) / 2.0),
		ends.y + floori((right_to - ends.y - bush_w) / 2.0)
	)


## Grass tile of a row; the two sides are out of step so they do not mirror each other.
static func grass_frame(row: int, right_side: bool) -> String:
	var variants := ViewConfig.GRASS_ROWS
	var shift := ViewConfig.GRASS_RIGHT_SHIFT if right_side else 0
	return variants[posmod(row + shift, variants.size())]


func _draw() -> void:
	if cfg == null:
		return
	var w := ViewConfig.VIEW_W
	var h := ViewConfig.VIEW_H
	var tile := ViewConfig.TILE
	# Flat colours first: if a tile frame were missing, the road would keep its colours instead of showing a hole.
	Draw.rect(self, Rect2i(0, 0, w, h), ViewConfig.GRASS)
	var barrier := ViewConfig.BARRIER_W
	var road := Rect2i(int(cfg.road_left) - barrier, 0, int(cfg.road_right - cfg.road_left) + barrier * 2, h)
	Draw.rect(self, road, ViewConfig.ASPHALT)

	# Tile rows scroll down as the road is travelled. `row` numbers rows along the road, so grass moves with it.
	var row := floori(scroll / float(tile)) + 1
	var y := posmod(scroll, tile) - tile
	var middle := w >> 1
	while y < h:
		for column: Dictionary in _columns:
			var x: int = column["x"]
			var name: String = column["frame"]
			if name.is_empty():
				name = grass_frame(row, x > middle)
			Draw.frame_at(self, atlas, name, Vector2i(x, y), ViewConfig.TILE_SCALE)
		y += tile
		row -= 1

	# Lane dashes between the lanes.
	var dash_offset := posmod(scroll, ViewConfig.DASH_PERIOD)
	var half_dash := ViewConfig.DASH_W >> 1
	for lane: int in range(1, cfg.lane_count):
		var x := int(cfg.road_left + cfg.lane_width * lane) - half_dash
		var dash_y := dash_offset - ViewConfig.DASH_PERIOD
		while dash_y < h:
			Draw.rect(self, Rect2i(x, dash_y, ViewConfig.DASH_W, ViewConfig.DASH_LENGTH), ViewConfig.WHITE)
			dash_y += ViewConfig.DASH_PERIOD

	# Bushes on the grass, the right side trailing the left.
	var bush_size := atlas.frame_size(ViewConfig.BUSH) * ViewConfig.BUSH_SCALE if atlas != null else Vector2i.ZERO
	if bush_size.x <= 0:
		return
	var at := bush_x(cfg, beside_panels, bush_size.x)
	var period := ViewConfig.BUSH_PERIOD
	var left_y := posmod(scroll, period) - period
	while left_y < h:
		Draw.frame_at(self, atlas, ViewConfig.BUSH, Vector2i(at.x, left_y), ViewConfig.BUSH_SCALE)
		left_y += period
	var right_y := posmod(scroll + ViewConfig.BUSH_STAGGER, period) - period
	while right_y < h:
		Draw.frame_at(self, atlas, ViewConfig.BUSH, Vector2i(at.y, right_y), ViewConfig.BUSH_SCALE)
		right_y += period
