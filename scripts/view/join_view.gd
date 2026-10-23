extends Node2D
## The join screen's drawing (B2): over the dimmed road, the title, six seat cards in the six player colours
## (player_colours.gd), the number of bots, whether the race can start, and the controls.
##
## A card is its seat's for good: its car stands in the middle in the seat's colour, with the colour's name under it.
## A taken card is lit in that colour: its border, and the badge along its top with its name (P1 to P6, or BOT for a
## bot's seat); a person's card says READY and a bot's CPU. A free card has a grey border and a dark badge, and asks to
## PRESS A (blinking), its car waiting in the colour the seat gives. Bots take the lowest free seats (seats.gd
## bot_seats()), so their cards move when a person joins or leaves. The bots fill every empty seat by themselves.

const ViewConfig := preload("res://scripts/view/view_config.gd")
const Atlas := preload("res://scripts/view/atlas.gd")
const Draw := preload("res://scripts/view/draw.gd")
const PlayerColours := preload("res://scripts/view/player_colours.gd")
const Seats := preload("res://scripts/input/seats.gd")
const Names := preload("res://scripts/app/names.gd")
const Config := preload("res://scripts/sim/config.gd")

const TITLE := "LOCAL"
const TITLE_TOP := 14
const SUBTITLE := "GAMEPAD: PRESS A     ALONE: ENTER ON THE KEYBOARD"
const SUBTITLE_TOP := 54
## Six cards in a row.
const CARD_W := 96
const CARD_H := 124
const CARD_GAP := 8
const CARD_TOP := 72
## Offsets in a card: the badge along its top (inside the border), the car's hitbox top, the colour's name, the state.
const CARD_BORDER := 2
const CARD_BADGE_H := 24
const CARD_LABEL_DY := 6
const CARD_CAR_DY := 40
const CARD_COLOUR_DY := 76
const CARD_STATE_DY := 102
const BOTS_TOP := 210
const STATUS_TOP := 236
## The controls, two lines on a dark band.
const HINTS := [
	"A JOIN    B LEAVE    BOTS FILL THE EMPTY SEATS",
	"START  RACE    BACK / ESC  TITLE",
	"NAME: UP / DOWN  LETTER    RIGHT  ADD    LEFT  DELETE",
]
const HINTS_TOP := 288
const HINTS_STEP := 16
## "PRESS A" on free cards blinks every this many seconds.
const BLINK_SECONDS := 0.5
## A free card's badge.
const FREE_BADGE := Color("#383838")

var atlas: Atlas
var font: Font
var cfg: Config
## What the cards show, taken from the seats (show_seats()): per seat, Seats.FREE, PERSON or BOT.
var kinds: Array[int] = []
var bots: int = 0
var min_bots: int = 0
var max_bots: int = 0
var can_start: bool = false
var cars: int = 0
## Seconds since the screen opened, for the blink.
var time: float = 0.0
## The seats' names (the app's); null: P1 to P6.
var names: Names = null


func setup(p_atlas: Atlas, p_cfg: Config) -> void:
	atlas = p_atlas
	font = p_atlas.font
	cfg = p_cfg
	queue_redraw()


## Takes what to draw from the seats.
func show_seats(seats: Seats, p_time: float = 0.0, p_names: Names = null) -> void:
	names = p_names
	kinds = []
	for seat in Seats.SEATS:
		kinds.append(seats.kind_of(seat))
	bots = seats.bots
	min_bots = seats.min_bots()
	max_bots = seats.max_bots()
	can_start = seats.can_start()
	cars = seats.cars()
	time = p_time
	queue_redraw()


## A seat's card.
static func card_rect(seat: int) -> Rect2i:
	var row_w := Seats.SEATS * CARD_W + (Seats.SEATS - 1) * CARD_GAP
	var left := (ViewConfig.VIEW_W - row_w) >> 1
	return Rect2i(left + seat * (CARD_W + CARD_GAP), CARD_TOP, CARD_W, CARD_H)


## What a card says at its foot.
static func state_text(kind: int) -> String:
	if kind == Seats.PERSON:
		return "READY"
	if kind == Seats.BOT:
		return "CPU"
	return "PRESS A"


## The line under the cards: whether Start starts a race now.
static func status_text(p_can_start: bool, p_cars: int, people: int) -> String:
	if people == 0:
		return "PRESS A TO JOIN"
	if p_can_start:
		return "PRESS START: %d CARS" % p_cars
	return "TWO CARS AT LEAST"


## The bots' line: they fill every empty seat.
static func bots_text(count: int) -> String:
	return "BOTS: %d" % count


func _draw() -> void:
	if font == null or kinds.is_empty():
		return
	var centre := ViewConfig.VIEW_W >> 1
	Draw.rect(self, Rect2i(0, 0, ViewConfig.VIEW_W, ViewConfig.VIEW_H), Color(0, 0, 0, ViewConfig.OVERLAY_DIM))
	Draw.shadowed_centred(self, font, centre, TITLE_TOP, TITLE, ViewConfig.TEXT_HUGE, ViewConfig.YELLOW)
	Draw.text_centred(self, font, centre, SUBTITLE_TOP, SUBTITLE, ViewConfig.TEXT_SMALL, ViewConfig.WHITE)
	var lit := floori(time / BLINK_SECONDS) % 2 == 0
	for seat in kinds.size():
		draw_card(seat, kinds[seat], lit)
	_draw_bots(centre)
	var people := kinds.count(Seats.PERSON)
	var status := status_text(can_start, cars, people)
	Draw.text_centred(self, font, centre, STATUS_TOP, status, ViewConfig.TEXT_SMALL, ViewConfig.YELLOW)
	var band := Rect2i(0, HINTS_TOP - 8, ViewConfig.VIEW_W, HINTS.size() * HINTS_STEP + 8)
	Draw.rect(self, band, Color(0, 0, 0, ViewConfig.BAND_ALPHA))
	var top := HINTS_TOP
	for line: String in HINTS:
		Draw.text_centred(self, font, centre, top, line, ViewConfig.TEXT_SMALL, ViewConfig.WHITE)
		top += HINTS_STEP


## "BOTS: n", under the cards.
func _draw_bots(centre: int) -> void:
	Draw.shadowed_centred(self, font, centre, BOTS_TOP, bots_text(bots), ViewConfig.TEXT_MEDIUM, ViewConfig.WHITE)


## One seat's card: a box with a border in the seat's colour (grey when free); the badge with its name, on the seat's
## colour (dark grey when free); its car, which waits on a free card too, so its colour shows; the colour's name; its
## state.
func draw_card(seat: int, kind: int, lit: bool) -> void:
	var r := card_rect(seat)
	var free := kind == Seats.FREE
	var colour := PlayerColours.colour(seat)
	Draw.box(self, r, ViewConfig.GREY if free else colour)
	var cx := r.position.x + (r.size.x >> 1)
	var inner := r.grow(-CARD_BORDER)
	var badge := Rect2i(inner.position, Vector2i(inner.size.x, CARD_BADGE_H))
	Draw.rect(self, badge, FREE_BADGE if free else colour)
	var name := PlayerColours.label(seat, kind != Seats.BOT)
	if names != null and kind == Seats.PERSON:
		name = names.name_of(seat)
	var name_size := ViewConfig.TEXT_MEDIUM if Draw.text_width(font, name, ViewConfig.TEXT_MEDIUM) <= inner.size.x - 4 else ViewConfig.TEXT_SMALL
	var ink := ViewConfig.GREY if free else PlayerColours.ink(seat)
	Draw.text_centred(self, font, cx, r.position.y + CARD_LABEL_DY + ((ViewConfig.TEXT_MEDIUM - name_size) >> 1), name, name_size, ink)
	var size := Vector2i(roundi(cfg.player_w), roundi(cfg.player_h))
	var box := Vector2i(cx - (size.x >> 1), r.position.y + CARD_CAR_DY)
	Draw.sprite_on_hitbox(self, atlas, PlayerColours.seat_sprite(ViewConfig.PLAYER, seat), box, size, colour)
	var colour_name: String = PlayerColours.NAMES[seat]
	Draw.text_centred(self, font, cx, r.position.y + CARD_COLOUR_DY, colour_name, ViewConfig.TEXT_SMALL, ViewConfig.GREY)
	if free and not lit:
		return
	var state_colour := ViewConfig.YELLOW if free else (ViewConfig.WHITE if kind == Seats.PERSON else ViewConfig.GREY)
	Draw.text_centred(self, font, cx, r.position.y + CARD_STATE_DY, state_text(kind), ViewConfig.TEXT_SMALL, state_colour)
