extends "res://tests/test_case.gd"
## The versus screens' layout (B2, scripts/view/versus_hud.gd and join_view.gd): every piece of a seat panel, a
## results table and a join card fits where it is drawn, nothing of the HUD covers the road while racing, and the
## widest texts fit. How it all looks is checked on the pictures (tools/screenshots.gd, docs/screenshots/07 to 11).

const VersusHud := preload("res://scripts/view/versus_hud.gd")
const JoinView := preload("res://scripts/view/join_view.gd")
const PlayerColours := preload("res://scripts/view/player_colours.gd")
const ViewConfig := preload("res://scripts/view/view_config.gd")
const Atlas := preload("res://scripts/view/atlas.gd")
const Draw := preload("res://scripts/view/draw.gd")
const Road := preload("res://scripts/view/road.gd")
const Seats := preload("res://scripts/input/seats.gd")
const Config := preload("res://scripts/sim/config.gd")
const Match := preload("res://scripts/sim/match.gd")

var atlas: Atlas
var font: Font
var cfg: Config


func before_all() -> void:
	atlas = Atlas.new()
	atlas.load_all()
	PlayerColours.add_frames(atlas)
	font = atlas.font
	cfg = Config.standard()


## The six seat panels fill the two side columns, three each, without touching one another, and stay on the grass:
## they never cover the road or its verges (x 168 to 472), where the cars are.
func test_the_seat_panels_stay_beside_the_road() -> void:
	var verge_left := Road.edge_left_x(cfg) - ViewConfig.TILE
	var verge_right_end := Road.edge_right_x(cfg) + ViewConfig.TILE * 2
	var road := Rect2i(verge_left, 0, verge_right_end - verge_left, ViewConfig.VIEW_H)
	for seat in Seats.SEATS:
		var r := VersusHud.seat_panel_rect(seat)
		assert_false(r.intersects(road), "seat %d's panel is off the road" % seat)
		assert_true(Rect2i(0, 0, ViewConfig.VIEW_W, ViewConfig.VIEW_H).encloses(r))
		for other in Seats.SEATS:
			if other != seat:
				assert_false(r.intersects(VersusHud.seat_panel_rect(other)), "seats %d and %d" % [seat, other])
	assert_eq(VersusHud.seat_panel_rect(2).end.y, ViewConfig.PANEL_LEFT.end.y, "three panels fill the column")


## Inside a panel's border: the car, the widest name with the pips beside it, the widest score, the gauge and both
## mark lines.
func test_a_seat_panels_contents_fit_inside_its_border() -> void:
	var r := VersusHud.seat_panel_rect(0)
	var inner := r.grow(-VersusHud.BORDER)
	var car_size := atlas.frame_size(PlayerColours.frame_name("car_red", 0)) * ViewConfig.SPRITE_SCALE
	var car := Rect2i(r.position + Vector2i(VersusHud.CAR_DX, VersusHud.CAR_DY), car_size)
	assert_true(inner.encloses(car), "the car %s" % car)
	var pips_w := Config.MATCH_WINS * VersusHud.PIP + (Config.MATCH_WINS - 1) * VersusHud.PIP_GAP
	var pips := Rect2i(r.end.x - VersusHud.INSET - pips_w, r.position.y + VersusHud.PIP_DY, pips_w, VersusHud.PIP)
	assert_true(inner.encloses(pips), "the pips")
	var medium := ViewConfig.TEXT_MEDIUM
	var person := Rect2i(r.position.x + VersusHud.NAME_DX, r.position.y + VersusHud.NAME_DY, Draw.text_width(font, "P6", medium), medium)
	assert_false(person.intersects(pips), "a person's name and pips")
	assert_false(person.intersects(car), "the name and the car")
	var bot := Rect2i(person.position, Vector2i(Draw.text_width(font, "BOT", medium), medium))
	assert_true(inner.encloses(bot), "BOT (bots have no pips)")
	var score_w := Draw.text_width(font, "999999", medium)
	assert_lt(score_w, inner.size.x - 2 * (VersusHud.INSET - VersusHud.BORDER) + 1, "the score")
	assert_gt(VersusHud.SCORE_DY, car.end.y - r.position.y - 1, "the score is under the car")
	var gauge := Rect2i(r.position.x + VersusHud.INSET, r.position.y + VersusHud.GAUGE_DY, r.size.x - 2 * VersusHud.INSET, VersusHud.GAUGE_H)
	assert_true(inner.encloses(gauge), "the gauge")
	assert_gt(VersusHud.GAUGE_DY, VersusHud.SCORE_DY + medium - 1, "the gauge is under the score")
	assert_gt(VersusHud.MARK_DY, VersusHud.GAUGE_DY + VersusHud.GAUGE_H - 1, "the marks are under the gauge")
	var small := ViewConfig.TEXT_SMALL
	assert_gt(VersusHud.PAD_MARK_DY, VersusHud.MARK_DY + small - 1, "NO PAD is under the other mark")
	assert_lt(VersusHud.PAD_MARK_DY + small, inner.end.y - r.position.y + 1, "NO PAD inside")
	for mark: String in ["OUT", "EDGE", "LOW FUEL", "NO PAD"]:
		assert_lt(Draw.text_width(font, mark, small), inner.size.x + 1, mark)


## The results tables: the badge, then the columns, none overlapping, each as wide as its widest cell, the table
## inside the panel's padding; a badge holds the widest name.
func test_the_results_table_fits_its_panel() -> void:
	var small := ViewConfig.TEXT_SMALL
	assert_lt(VersusHud.BADGE_W, VersusHud.COLUMN_X[0] + 1, "the badge before the first column")
	for i in range(1, VersusHud.COLUMN_X.size()):
		assert_gt(VersusHud.COLUMN_X[i], VersusHud.COLUMN_X[i - 1] + VersusHud.COLUMN_W[i - 1] - 1, "column %d" % i)
	for i: int in [0, 1]:
		assert_lt(Draw.text_width(font, "999999", small), VersusHud.COLUMN_W[i] + 1)
	assert_lt(Draw.text_width(font, "OUT", small), VersusHud.COLUMN_W[2] + 1)
	var pips_w := Config.MATCH_WINS * VersusHud.PIP + (Config.MATCH_WINS - 1) * VersusHud.PIP_GAP
	assert_lt(pips_w, VersusHud.COLUMN_W[3] + 1, "the pips")
	for heading: String in ["POINTS", "TOTAL", "DIST"]:
		assert_lt(Draw.text_width(font, heading, small), VersusHud.COLUMN_W[0] + 1, heading)
	assert_lt(Draw.text_width(font, "BOT", small), VersusHud.BADGE_W - 3, "BOT in a badge")
	assert_gt(VersusHud.BADGE_H, small + 1, "a badge is taller than its text")
	assert_lt(VersusHud.BADGE_H, ViewConfig.OVERLAY_LINE_STEP + 1, "badges of two rows do not touch")
	var m := Match.create(cfg, 1, 6, 0b111111)
	m.phase = Match.ROUND_OVER
	var overlay := VersusHud.overlay_for(m, [0, 1, 2, 3, 4, 5] as Array[int])
	var r := VersusHud.panel_rect(overlay)
	var left := VersusHud.table_left(r)
	var table_w: int = VersusHud.COLUMN_X.back() + VersusHud.COLUMN_W.back()
	assert_gt(left, r.position.x + ViewConfig.OVERLAY_PADDING - 1, "the table inside the padding")
	assert_lt(left + table_w, r.end.x - ViewConfig.OVERLAY_PADDING + 1)


## Each join card holds its badge with the widest name, the car, the widest colour name and the widest state.
func test_a_join_cards_contents_fit() -> void:
	var r := JoinView.card_rect(0)
	var inner := r.grow(-JoinView.CARD_BORDER)
	assert_lt(Draw.text_width(font, "BOT", ViewConfig.TEXT_MEDIUM), inner.size.x + 1)
	assert_lt(JoinView.CARD_LABEL_DY + ViewConfig.TEXT_MEDIUM, JoinView.CARD_BORDER + JoinView.CARD_BADGE_H + 1, "the name in its badge")
	var car_top := r.position.y + JoinView.CARD_CAR_DY
	assert_gt(car_top, r.position.y + JoinView.CARD_BORDER + JoinView.CARD_BADGE_H, "the car under the badge")
	assert_lt(car_top + roundi(cfg.player_h), r.position.y + JoinView.CARD_COLOUR_DY, "the car above the colour's name")
	for name: String in PlayerColours.NAMES:
		assert_lt(Draw.text_width(font, name, ViewConfig.TEXT_SMALL), inner.size.x + 1, name)
	for kind: int in [Seats.FREE, Seats.PERSON, Seats.BOT]:
		assert_lt(Draw.text_width(font, JoinView.state_text(kind), ViewConfig.TEXT_SMALL), inner.size.x + 1)
	assert_lt(JoinView.CARD_STATE_DY + ViewConfig.TEXT_SMALL, JoinView.CARD_H - JoinView.CARD_BORDER + 1, "the state inside")
	assert_gt(JoinView.CARD_STATE_DY, JoinView.CARD_COLOUR_DY + ViewConfig.TEXT_SMALL - 1)
	assert_lt(JoinView.card_rect(0).end.y, JoinView.BOTS_TOP, "the bots' line under the cards")
	var bots_w := Draw.text_width(font, "< " + JoinView.bots_text(5) + " >", ViewConfig.TEXT_MEDIUM) + 2 * ViewConfig.TEXT_MEDIUM
	assert_lt(bots_w, ViewConfig.VIEW_W)
	assert_lt(JoinView.STATUS_TOP + ViewConfig.TEXT_SMALL, JoinView.HINTS_TOP - 8, "the status above the hints' band")
