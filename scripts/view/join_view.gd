extends Node2D
## The join screen's drawing (B2; first version, B2b gives it its final look): over the dimmed road, the title, six seat
## cards in the six player colours (player_colours.gd), the number of bots, whether the race can start, and the
## controls.
##
## A card shows its seat: P1 to P6, or BOT for a bot's seat, in the seat's colour; the seat's car for a person or a bot;
## and "PRESS A" (blinking) on a free seat or "READY" for a person. Bots take the lowest free seats (seats.gd
## bot_seats()), so their cards move when a person joins or leaves.

const ViewConfig := preload("res://scripts/view/view_config.gd")
const Atlas := preload("res://scripts/view/atlas.gd")
const Draw := preload("res://scripts/view/draw.gd")
const PlayerColours := preload("res://scripts/view/player_colours.gd")
const Seats := preload("res://scripts/input/seats.gd")
const Config := preload("res://scripts/sim/config.gd")

const TITLE := "VERSUS"
const TITLE_TOP := 16
const SUBTITLE := "EVERY PLAYER: PRESS A ON YOUR GAMEPAD"
const SUBTITLE_TOP := 56
## Six cards in a row.
const CARD_W := 96
const CARD_H := 120
const CARD_GAP := 8
const CARD_TOP := 76
const CARD_LABEL_DY := 10
const CARD_CAR_DY := 40
const CARD_STATE_DY := 96
const BOTS_TOP := 212
const STATUS_TOP := 240
## The controls, two lines on a dark band.
const HINTS := [
	"A JOIN    B LEAVE    LEFT / RIGHT  BOTS",
	"START  RACE    BACK / ESC  TITLE",
]
const HINTS_TOP := 288
const HINTS_STEP := 16
## "PRESS A" on free cards blinks every this many seconds.
const BLINK_SECONDS := 0.5
## The free card's dimmed parts.
const FREE_ALPHA := 0.5

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


func setup(p_atlas: Atlas, p_cfg: Config) -> void:
	atlas = p_atlas
	font = p_atlas.font
	cfg = p_cfg
	queue_redraw()


## Takes what to draw from the seats.
func show_seats(seats: Seats, p_time: float = 0.0) -> void:
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


## What a card says under the car ("" for a bot, whose name says it).
static func state_text(kind: int) -> String:
	if kind == Seats.PERSON:
		return "READY"
	if kind == Seats.BOT:
		return ""
	return "PRESS A"


## The line under the cards: whether Start starts a race now.
static func status_text(p_can_start: bool, p_cars: int, people: int) -> String:
	if people == 0:
		return "PRESS A TO JOIN"
	if p_can_start:
		return "PRESS START: %d CARS" % p_cars
	return "TWO CARS AT LEAST"


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
	var bot_line := "< BOTS: %d >" % bots
	Draw.shadowed_centred(self, font, centre, BOTS_TOP, bot_line, ViewConfig.TEXT_MEDIUM, ViewConfig.WHITE)
	var people := kinds.count(Seats.PERSON)
	var status := status_text(can_start, cars, people)
	Draw.text_centred(self, font, centre, STATUS_TOP, status, ViewConfig.TEXT_SMALL, ViewConfig.YELLOW)
	var band := Rect2i(0, HINTS_TOP - 8, ViewConfig.VIEW_W, HINTS.size() * HINTS_STEP + 8)
	Draw.rect(self, band, Color(0, 0, 0, ViewConfig.BAND_ALPHA))
	var top := HINTS_TOP
	for line: String in HINTS:
		Draw.text_centred(self, font, centre, top, line, ViewConfig.TEXT_SMALL, ViewConfig.WHITE)
		top += HINTS_STEP


## One seat's card: a box with a border in the seat's (light) colour, grey when free; its name, its car and its state.
func draw_card(seat: int, kind: int, lit: bool) -> void:
	var r := card_rect(seat)
	var free := kind == Seats.FREE
	var border := ViewConfig.GREY if free else PlayerColours.text_colour(seat)
	Draw.box(self, r, border)
	var cx := r.position.x + (r.size.x >> 1)
	var name_colour := Color(PlayerColours.text_colour(seat), FREE_ALPHA if free else 1.0)
	var name := PlayerColours.label(seat, kind != Seats.BOT)
	Draw.text_centred(self, font, cx, r.position.y + CARD_LABEL_DY, name, ViewConfig.TEXT_MEDIUM, name_colour)
	if not free:
		var size := Vector2i(roundi(cfg.player_w), roundi(cfg.player_h))
		var box := Vector2i(cx - (size.x >> 1), r.position.y + CARD_CAR_DY)
		var spec := PlayerColours.seat_sprite(ViewConfig.PLAYER, seat)
		Draw.sprite_on_hitbox(self, atlas, spec, box, size, PlayerColours.colour(seat))
	var state := state_text(kind)
	if state.is_empty() or (free and not lit):
		return
	var state_colour := ViewConfig.WHITE if free else PlayerColours.text_colour(seat)
	Draw.text_centred(self, font, cx, r.position.y + CARD_STATE_DY, state, ViewConfig.TEXT_SMALL, state_colour)
