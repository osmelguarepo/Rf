extends "res://tests/test_case.gd"
## The versus seats (scripts/input/seats.gd, B2; docs/GODOT_PLAN.md §5, docs/DECISIONES_MULTIJUGADOR.md §2): pads join
## on the lowest free seat and keep its colour, the number of bots (one at least with one person, six cars at most),
## the match's line-up, one byte per seat, and pads coming and going in a race (the same GUID takes its seat back;
## otherwise A on a pad that holds no seat takes the lowest orphan seat). GUIDs come from a fake source; held controls
## from Input's real state (Input.parse_input_event()), let go in after_each().

const Seats := preload("res://scripts/input/seats.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")
const Held := preload("res://scripts/input/held.gd")
const World := preload("res://scripts/sim/world.gd")
const Car := preload("res://scripts/sim/car.gd")
const Config := preload("res://scripts/sim/config.gd")

## Joypad devices the tests use (other test files use 0 to 7).
const PADS: Array[int] = [20, 21, 22, 23, 24, 25, 26, 27]

var seats: Seats
## device -> GUID, the fake source.
var guids := {}


func before_each() -> void:
	guids = {}
	seats = Seats.new()
	seats.guid_of = func(device: int) -> String: return guids.get(device, "")


func after_each() -> void:
	# The fake source refers to this test, which refers to the seats: let go of both, or neither is ever freed.
	seats.guid_of = Callable()
	seats = null
	for device: int in PADS:
		for button: JoyButton in [JOY_BUTTON_A, JOY_BUTTON_B, JOY_BUTTON_START, JOY_BUTTON_DPAD_LEFT]:
			Input.parse_input_event(_button(device, button, false))
	Input.flush_buffered_events()


## Pads take the lowest free seat in the order they join, and keep it: a seat's colour never changes.
func test_pads_join_on_the_lowest_free_seat_and_keep_it() -> void:
	assert_eq([seats.join(20), seats.join(21), seats.join(22)], [0, 1, 2])
	assert_eq(seats.join(21), -1, "a pad that holds a seat cannot join again")
	assert_eq(seats.leave(21), 1)
	assert_eq(seats.seat_of(21), -1)
	assert_eq(seats.leave(21), -1, "nothing to leave")
	assert_eq(seats.seat_of(22), 2, "the others keep their seats")
	assert_eq(seats.join(23), 1, "the next pad takes the lowest free seat")
	assert_eq(seats.join(24), 3)
	assert_eq([seats.seat_of(20), seats.seat_of(23), seats.seat_of(22), seats.seat_of(24)], [0, 1, 2, 3])
	assert_eq(seats.kind_of(4), Seats.BOT, "bots fill the empty seats")
	assert_eq(seats.kind_of(0), Seats.PERSON)


## LOCAL: the bots fill every empty seat by themselves, so six cars always race (and never fewer than two); a person who
## joins takes a bot's place, and a bot comes back when the person leaves. Nobody seated: no bots.
func test_bots_fill_every_empty_seat_up_to_six_cars() -> void:
	assert_eq(seats.bots, 0, "nobody: no bots")
	seats.join(20)
	assert_eq(seats.bots, 5, "the first person gets five bots")
	assert_eq(seats.cars(), 6)
	seats.join(21)
	assert_eq(seats.bots, 4)
	seats.leave(21)
	assert_eq(seats.bots, 5, "the bot comes back when the person leaves")
	for device: int in [21, 22, 23, 24, 25]:
		seats.join(device)
	assert_eq(seats.people(), 6)
	assert_eq(seats.bots, 0, "six people leave no room for a bot")
	assert_eq(seats.join(26), -1, "a seventh pad finds no seat")
	for device: int in [21, 22, 23, 24, 25]:
		seats.leave(device)
	assert_eq(seats.bots, 5, "back to one person: five bots")
	seats.leave(20)
	assert_eq(seats.bots, 0, "nobody: no bots")
	assert_false(seats.can_start())


## set_bots() (used by tests and tools) still bounds the choice: a lone person keeps one bot at least.
func test_set_bots_still_bounds_the_choice() -> void:
	seats.join(20)
	assert_eq(seats.set_bots(0), 1, "one person: one bot at least")
	assert_eq(seats.set_bots(9), 5, "six cars at most")
	seats.join(21)
	assert_eq(seats.set_bots(0), 0, "two people need no bot")
	assert_eq(seats.set_bots(2), 2)
	seats.leave(21)
	assert_eq(seats.bots, 2, "the choice stays")


## Bots take the lowest free seats; the line-up is every seat with a car, in seat order, so the world's slots are
## contiguous while seats keep their colours.
func test_the_line_up_maps_world_slots_to_seats() -> void:
	for device: int in [20, 21, 22, 23]:
		seats.join(device)
	seats.leave(20)
	seats.leave(22)
	assert_eq(seats.set_bots(1), 1)
	assert_eq(seats.bot_seats(), [0] as Array[int])
	assert_eq(seats.kind_of(0), Seats.BOT)
	assert_eq(seats.next_lineup(), [0, 1, 3] as Array[int])
	assert_true(seats.lock())
	assert_eq(seats.lineup, [0, 1, 3] as Array[int])
	assert_eq(seats.humans_mask(), 0b110, "slots 1 and 2 are people's, slot 0 the bot's")
	assert_eq([seats.seat_at(0), seats.seat_at(2), seats.seat_at(3)], [0, 3, -1])
	assert_true(World.versus_valid(Config.standard(), seats.lineup.size(), seats.humans_mask()))
	assert_eq(seats.join(24), -1, "nobody joins while a match is on")
	assert_eq(seats.leave(21), -1, "nor leaves")
	assert_eq(seats.set_bots(3), 1, "nor changes the bots")


## Two people and no bots: the line-up skips the free seats between them.
func test_a_line_up_of_two_people_far_apart() -> void:
	for device: int in [20, 21, 22, 23, 24]:
		seats.join(device)
	for device: int in [21, 22, 23]:
		seats.leave(device)
	seats.set_bots(0)
	assert_true(seats.lock())
	assert_eq(seats.lineup, [0, 4] as Array[int])
	assert_eq(seats.humans_mask(), 0b11)


## A match needs World.versus_valid(): somebody, and two cars.
func test_a_match_starts_only_when_valid() -> void:
	assert_false(seats.can_start(), "nobody")
	seats.set_bots(3)
	assert_false(seats.can_start(), "bots alone")
	assert_false(seats.lock())
	assert_false(seats.locked)
	seats.join(20)
	assert_true(seats.can_start())
	seats.bots = 0
	assert_false(seats.can_start(), "one car")
	assert_false(seats.lock())
	seats.set_bots(1)
	assert_true(seats.lock())
	assert_true(seats.locked)


## Each slot's byte: the pad's held controls with the single-player mapping and its own presses, once; 0xFF for a
## bot's seat; no input past the line-up.
func test_each_slot_gets_its_pads_byte_and_bots_get_0xff() -> void:
	seats.join(20)
	seats.join(21)
	seats.set_bots(1)
	assert_eq(seats.step_bytes(3), PackedByteArray([PlayerInput.NONE, PlayerInput.NONE, PlayerInput.NONE]), "no line-up")
	seats.lock()
	_send(_button(20, JOY_BUTTON_A, true))
	_send(_button(21, JOY_BUTTON_DPAD_LEFT, true))
	seats.handle_event(_button(21, JOY_BUTTON_START, true))
	var held_a := Held.to_byte(Held.ACCEL | Held.HIGH_GEAR)
	var left := Held.to_byte(Held.LEFT)
	assert_eq(seats.step_bytes(4), PackedByteArray([
		held_a, PlayerInput.with_edges(left, PlayerInput.PAUSE | PlayerInput.CONFIRM), PlayerInput.BOT, PlayerInput.NONE
	]))
	assert_eq(seats.step_bytes(3), PackedByteArray([held_a, left, PlayerInput.BOT]), "a press counts once")
	assert_true(seats.handle_event(_button(20, JOY_BUTTON_A, true)), "A on a seated pad is a confirm press")
	assert_false(seats.handle_event(_button(26, JOY_BUTTON_A, true)), "a pad without a seat presses nothing")
	assert_false(seats.handle_event(_key(KEY_ENTER)), "the keyboard drives nothing in versus")
	assert_eq(seats.take_presses(), PlayerInput.CONFIRM)
	assert_eq(seats.take_presses(), 0)


## A pad that goes away in a race orphans its seat: 0xFF from the next step (its bot drives), and the seat stays a
## person's. The same pad (GUID) coming back takes it again, on whatever device it now has.
func test_a_pad_that_goes_away_is_driven_by_the_bot_until_it_comes_back() -> void:
	guids = {20: "pad-a", 21: "pad-b", 25: "pad-b"}
	seats.join(20)
	seats.join(21)
	seats.set_bots(0)
	seats.lock()
	_send(_button(21, JOY_BUTTON_A, true))
	seats.handle_event(_button(21, JOY_BUTTON_START, true))
	seats.connection_changed(21, false)
	assert_true(seats.is_orphan(1))
	assert_eq(seats.kind_of(1), Seats.PERSON)
	assert_eq(seats.step_bytes(2)[1], PlayerInput.BOT, "0xFF at once, and the press made before is dropped")
	seats.connection_changed(24, true)
	assert_true(seats.is_orphan(1), "another pad's GUID does not take it")
	seats.connection_changed(25, true)
	assert_eq(seats.seat_of(25), 1, "the same GUID takes its seat back")
	assert_false(seats.is_orphan(1))
	assert_ne(seats.step_bytes(2)[1], PlayerInput.BOT)


## A pad that connects with no orphan seat of its GUID waits; A (claim()) gives it the orphan seat of its GUID if any,
## or else the lowest orphan seat.
func test_a_by_another_pad_takes_the_lowest_orphan_seat() -> void:
	guids = {20: "x", 21: "y", 22: "z", 23: "w", 30: "z", 31: "q"}
	for device: int in [20, 21, 22, 23]:
		seats.join(device)
	seats.set_bots(0)
	seats.lock()
	seats.connection_changed(21, false)
	seats.connection_changed(22, false)
	assert_eq(seats.claim(20), -1, "a pad that holds a seat claims none")
	assert_eq(seats.claim(30), 2, "its own GUID's seat first")
	assert_eq(seats.claim(31), 1, "otherwise the lowest orphan seat")
	assert_eq(seats.claim(32), -1, "no orphan seat left")
	assert_eq([seats.seat_of(31), seats.seat_of(30)], [1, 2])
	seats.connection_changed(31, false)
	assert_eq(seats.claim(33), 1)


## Pads of one model share a GUID: the first back takes the lower of their seats.
func test_identical_pads_come_back_in_seat_order() -> void:
	guids = {20: "same", 21: "other", 22: "same", 40: "same", 41: "same"}
	for device: int in [20, 21, 22]:
		seats.join(device)
	seats.lock()
	seats.connection_changed(22, false)
	seats.connection_changed(20, false)
	seats.connection_changed(41, true)
	seats.connection_changed(40, true)
	assert_eq([seats.seat_of(41), seats.seat_of(40)], [0, 2])


## On the join screen a pad that goes away leaves its seat; open() (back from a match) frees the orphan seats and keeps
## the pads that are still here and the bots.
func test_pads_that_go_away_leave_outside_a_race() -> void:
	seats.join(20)
	seats.join(21)
	seats.join(22)
	seats.set_bots(2)
	seats.connection_changed(21, false)
	assert_eq(seats.kind_of(1), Seats.BOT, "freed; a bot takes the lowest free seat")
	assert_eq(seats.people(), 2)
	seats.lock()
	seats.connection_changed(22, false)
	assert_true(seats.is_orphan(2))
	seats.open()
	assert_false(seats.locked)
	assert_eq(seats.lineup, [] as Array[int])
	assert_eq(seats.seat_of(20), 0)
	assert_eq(seats.people(), 1)
	assert_eq(seats.bots, 2)
	assert_eq(seats.kind_of(2), Seats.BOT)


## The program's presses (focus loss, Esc) go to the lowest person's seat that has its pad; with no pad left, to the
## lowest person's seat, whose byte then carries the press instead of 0xFF for that one step.
func test_program_presses_go_to_a_persons_seat() -> void:
	seats.join(20)
	seats.join(21)
	seats.leave(20)
	seats.set_bots(1)
	seats.lock()
	assert_eq(seats.lineup, [0, 1] as Array[int])
	assert_eq(seats.program_slot(), 1, "slot 0 is a bot's")
	seats.press(PlayerInput.PAUSE)
	var bytes := seats.step_bytes(2)
	assert_eq(bytes[0], PlayerInput.BOT)
	assert_true(PlayerInput.pause(bytes[1]))
	assert_false(PlayerInput.pause(seats.step_bytes(2)[1]), "once")
	seats.connection_changed(21, false)
	seats.press(PlayerInput.PAUSE)
	assert_eq(seats.step_bytes(2)[1], PlayerInput.NONE | PlayerInput.PAUSE, "no pad: the press, no input")
	assert_eq(seats.step_bytes(2)[1], PlayerInput.BOT, "then the bot again")


## An orphan seat's pause press pauses a running world without moving anything, so no car goes undriven.
func test_a_press_on_an_orphan_seat_pauses_without_moving() -> void:
	var world := World.versus(Config.standard(), 5, 2, 0b01)
	for i in 30:
		world.step(PackedByteArray([PlayerInput.BOT, PlayerInput.BOT]))
	var before := _cars(world)
	assert_gt(world.players[0].speed, 0.0, "the bot drove seat 0")
	world.step(PackedByteArray([PlayerInput.NONE | PlayerInput.PAUSE, PlayerInput.BOT]))
	assert_eq(world.phase, World.PAUSED)
	assert_eq(_cars(world), before, "nothing moved")


## Without a fake source, GUIDs come from the engine, and only for connected pads: no error for a synthetic device.
func test_the_engines_guid_is_empty_for_a_pad_it_does_not_know() -> void:
	assert_eq(Seats.engine_guid(57), "")
	assert_eq(Seats.engine_guid(-1), "")
	var plain := Seats.new()
	assert_eq(plain.join(57), 0)
	assert_eq(plain.seat_guid[0], "")


func test_reset_frees_everything() -> void:
	seats.join(20)
	seats.set_bots(3)
	seats.lock()
	seats.press(PlayerInput.PAUSE)
	seats.reset()
	assert_eq([seats.people(), seats.bots, seats.locked, seats.lineup.size(), seats.take_presses()], [0, 0, false, 0, 0])


# --- helpers ---------------------------------------------------------------------------------------------------------


## Where each car is and how it goes: [x, y_world, speed, fuel] per seat.
static func _cars(world: World) -> Array:
	var out: Array = []
	for p: Car in world.players:
		out.append([p.x, p.y_world, p.speed, p.fuel])
	return out


## Input's state, as the engine would keep it (Seats reads held controls from Input).
static func _send(event: InputEvent) -> void:
	Input.parse_input_event(event)
	Input.flush_buffered_events()


static func _button(device: int, button: JoyButton, pressed: bool) -> InputEventJoypadButton:
	var event := InputEventJoypadButton.new()
	event.device = device
	event.button_index = button
	event.pressed = pressed
	return event


static func _key(code: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = true
	return event
