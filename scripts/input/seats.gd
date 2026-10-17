extends "res://scripts/input/local_input.gd"
## Versus input (B2; docs/GODOT_PLAN.md §5, docs/DECISIONES_MULTIJUGADOR.md §2): six seats, each a person's joypad, a
## bot or nobody, and one input byte per seat for every simulation step. The app makes it App.input on the join
## screen and in versus races (single player keeps local_input.gd, which this extends), so it answers the same calls:
## handle_event(), connection_changed(), step_bytes(), take_presses(), press(), clear_presses() and held().
##
## Seats are numbered 0 to 5 and each keeps its colour for good (scripts/view/player_colours.gd): seat s is P(s + 1).
## - The join screen (not locked). join(device) puts a pad that holds no seat on the lowest free seat; leave(device)
##   frees its seat; set_bots(n) chooses how many bots there are, and they take the lowest free seats (bot_seats()).
##   The rules bound the count the players chose: with one person there is at least one bot (two cars at least, plan
##   §7), and never more than six cars, so a pad that joins when people and bots fill every seat takes a bot's place.
##   `bots` is the count within the bounds; the choice stays, so the bot added for a lone person goes again when a
##   second person joins, and a bot that gave way to a person comes back when the person leaves.
## - lock() fixes a match's line-up: the people's seats and the bots' seats, in seat order, become the world's slots
##   0, 1, ... (lineup[slot] is the seat, so a seat keeps its colour whatever its slot). open() ends it.
## - A race (locked). step_bytes() gives each slot its pad's held controls (Pads.held_of(), the single-player mapping)
##   plus the presses that pad made since the last step; PlayerInput.BOT (0xFF) for a bot's seat and for a person's
##   seat whose pad has gone, an orphan seat, whose car its bot drives without stopping the round (plan §5).
## - Pads coming and going (connection_changed(), which the app calls from Input.joy_connection_changed). A pad that
##   goes away frees its seat on the join screen, and orphans it in a race: its byte is 0xFF from the next step. A pad
##   that connects in a race takes back the lowest orphan seat whose pad had its GUID. Otherwise claim(device), when a
##   pad that holds no seat presses A in a race, gives it the lowest orphan seat. A seat never changes its colour.
## - The keyboard drives nothing here (versus is pads only); press() latches the program's presses (the pause when the
##   window loses focus, or Esc), which go to the lowest person's seat (program_slot()).
##
## GUIDs come from guid_of: engine_guid() is Input.get_joy_guid() for a connected pad and "" for any other device (the
## engine logs an error for a device it does not know, and synthetic devices are not connected); a test sets its own.
## "" never matches. Pads of one model share a GUID, so when two of them have both gone, the first to come back takes
## the lower of their seats, whichever pad it is.

const Config := preload("res://scripts/sim/config.gd")
const World := preload("res://scripts/sim/world.gd")

const SEATS := Config.VERSUS_SEATS_MAX
const NO_DEVICE := -1
## What a seat is (kind_of()).
const FREE := 0
const PERSON := 1
const BOT := 2

## device -> GUID, "" when unknown.
var guid_of: Callable
## Per seat: true while a person holds it, with a pad or (in a race) as an orphan.
var taken: Array[bool] = []
## Per seat: the device of its pad, or NO_DEVICE (free, a bot's, or orphaned).
var seat_device: Array[int] = []
## Per seat: the GUID of its pad, kept while orphaned ("" unknown).
var seat_guid: Array[String] = []
## Per seat: presses its pad made that no step has taken yet (PlayerInput.PAUSE and CONFIRM bits).
var seat_pending: Array[int] = []
## The number of bots: the players' choice within the rules' bounds (min_bots() to max_bots()).
var bots: int = 0
## The number of bots the players chose on the join screen (set_bots()).
var wanted_bots: int = 0
## True from lock() to open(): a match is on and its line-up is fixed.
var locked: bool = false
## While locked: world slot -> seat.
var lineup: Array[int] = []


func _init() -> void:
	super()
	guid_of = engine_guid
	reset()


## The engine's GUID of a connected pad, or "".
static func engine_guid(device: int) -> String:
	if device < 0 or not Input.get_connected_joypads().has(device):
		return ""
	return Input.get_joy_guid(device)


## Every seat free, no bots, no line-up, no presses.
func reset() -> void:
	taken = []
	seat_device = []
	seat_guid = []
	seat_pending = []
	for seat in SEATS:
		taken.append(false)
		seat_device.append(NO_DEVICE)
		seat_guid.append("")
		seat_pending.append(0)
	bots = 0
	wanted_bots = 0
	locked = false
	lineup = []
	pending = 0


# --- Queries ---------------------------------------------------------------------------------------------------------


## The seat a pad holds, or -1.
func seat_of(device: int) -> int:
	return -1 if device < 0 else seat_device.find(device)


## The seat of a world slot while locked, or -1.
func seat_at(slot: int) -> int:
	return lineup[slot] if slot >= 0 and slot < lineup.size() else -1


## FREE, PERSON or BOT. Bots are the line-up's other seats while locked, and the lowest free seats before.
func kind_of(seat: int) -> int:
	if taken[seat]:
		return PERSON
	if locked:
		return BOT if lineup.has(seat) else FREE
	return BOT if bot_seats().has(seat) else FREE


## True while a seat's pad is here.
func has_pad(seat: int) -> bool:
	return seat_device[seat] != NO_DEVICE


## True for a person's seat whose pad has gone (only in a race: on the join screen the seat is freed).
func is_orphan(seat: int) -> bool:
	return taken[seat] and seat_device[seat] == NO_DEVICE


## The number of people.
func people() -> int:
	return taken.count(true)


func min_bots() -> int:
	return 1 if people() == 1 else 0


func max_bots() -> int:
	return SEATS - people()


## The cars of a match started now: people and bots.
func cars() -> int:
	return people() + bots


## The seats bots take before a match: the lowest free ones, `bots` of them.
func bot_seats() -> Array[int]:
	var out: Array[int] = []
	for seat in SEATS:
		if out.size() >= bots:
			break
		if not taken[seat]:
			out.append(seat)
	return out


## The line-up of a match started now: the people's and the bots' seats, in seat order.
func next_lineup() -> Array[int]:
	var bot := bot_seats()
	var out: Array[int] = []
	for seat in SEATS:
		if taken[seat] or bot.has(seat):
			out.append(seat)
	return out


## The human mask of a line-up for World.versus() and Match.create(): bit (1 << slot) for each person's seat.
func humans_of(slots: Array[int]) -> int:
	var mask := 0
	for slot in slots.size():
		if taken[slots[slot]]:
			mask |= 1 << slot
	return mask


## The human mask of the locked line-up.
func humans_mask() -> int:
	return humans_of(lineup)


## True when a match can start now: World.versus_valid() holds for the line-up (two to six cars, a person among them).
func can_start() -> bool:
	var slots := next_lineup()
	return World.versus_valid(Config.standard(), slots.size(), humans_of(slots))


# --- The join screen -------------------------------------------------------------------------------------------------


## Puts a pad that holds no seat on the lowest free seat. Returns the seat, or -1: locked, a pad that already holds a
## seat, or six people already. If people and bots filled every seat, a bot gives way.
func join(device: int) -> int:
	if locked or device < 0 or seat_of(device) >= 0:
		return -1
	var seat := taken.find(false)
	if seat < 0:
		return -1
	_attach(seat, device, guid_of.call(device))
	_clamp_bots()
	return seat


## Frees the seat of a pad. Returns the seat, or -1 (locked, or the pad holds no seat).
func leave(device: int) -> int:
	var seat := seat_of(device)
	if locked or seat < 0:
		return -1
	_free(seat)
	_clamp_bots()
	return seat


## Chooses the number of bots, kept from min_bots() to max_bots(). Returns it. Not while locked.
func set_bots(count: int) -> int:
	if not locked:
		wanted_bots = clampi(count, min_bots(), max_bots())
		bots = wanted_bots
	return bots


## Fixes the line-up for a match. Returns false, and changes nothing, when a match cannot start.
func lock() -> bool:
	if locked:
		return true
	if not can_start():
		return false
	lineup = next_lineup()
	locked = true
	clear_presses()
	return true


## Back to the join screen: the line-up ends, a seat whose pad has gone is freed, the pads still here stay on their
## seats and the bots stay chosen.
func open() -> void:
	locked = false
	lineup = []
	for seat in SEATS:
		if is_orphan(seat):
			_free(seat)
	_clamp_bots()
	clear_presses()


# --- A race ----------------------------------------------------------------------------------------------------------


## A pad that holds no seat pressed A in a race: it takes the lowest orphan seat whose pad had its GUID, or else the
## lowest orphan seat. Returns the seat, or -1 (no race, a pad that holds a seat, or no orphan seat).
func claim(device: int) -> int:
	if not locked or device < 0 or seat_of(device) >= 0:
		return -1
	var guid: String = guid_of.call(device)
	var seat := _orphan_with(guid)
	if seat < 0:
		seat = _orphan_with("", true)
	if seat >= 0:
		_attach(seat, device, guid)
	return seat


## Follows Input.joy_connection_changed: see the class comment.
func connection_changed(device: int, connected: bool) -> void:
	super.connection_changed(device, connected)
	var seat := seat_of(device)
	if not connected:
		if seat < 0:
			return
		if locked:
			seat_device[seat] = NO_DEVICE
			seat_pending[seat] = 0
		else:
			_free(seat)
			_clamp_bots()
		return
	if seat >= 0 or not locked:
		return
	var guid: String = guid_of.call(device)
	var orphan := _orphan_with(guid)
	if orphan >= 0:
		_attach(orphan, device, guid)


## Latches the presses a pad's event makes for its seat. Keys and pads that hold no seat latch nothing. Returns true
## if a press was latched.
func handle_event(event: InputEvent) -> bool:
	if not (event is InputEventJoypadButton or event is InputEventJoypadMotion):
		return false
	var bits := pads.presses_of(event)
	var seat := seat_of(event.device)
	if bits == 0 or seat < 0:
		return false
	seat_pending[seat] = PlayerInput.latch(seat_pending[seat], bits)
	return true


## The bytes of one step for a world of `slots` seats, in slot order: see the class comment. A slot past the
## line-up (or with no line-up) gets no input. The program's presses go to program_slot() on this step only.
func step_bytes(slots: int = 1) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(maxi(slots, 1))
	bytes.fill(PlayerInput.NONE)
	var program := pending
	pending = 0
	var program_at := program_slot() if program != 0 else -1
	for slot in bytes.size():
		var seat := seat_at(slot)
		if seat >= 0:
			bytes[slot] = seat_byte(seat, program if slot == program_at else 0)
	return bytes


## One seat's byte for a step, taking its pad's presses (and `extra` presses of the program): 0xFF for a bot's seat;
## for an orphan seat 0xFF too, unless the program pressed (then no input but the press, so that the step pauses even
## when no pad is here: a step that pauses moves nothing, so no car goes without its bot for it).
func seat_byte(seat: int, extra: int = 0) -> int:
	var presses := PlayerInput.latch(seat_pending[seat], extra)
	seat_pending[seat] = 0
	if not taken[seat]:
		return PlayerInput.BOT
	if seat_device[seat] == NO_DEVICE:
		return PlayerInput.BOT if presses == 0 else Held.to_byte(0, presses)
	return Held.to_byte(Pads.held_of(seat_device[seat]), presses)


## The slot the program's presses go to: the lowest person's seat with its pad, or else the lowest person's seat; -1
## with no line-up.
func program_slot() -> int:
	var orphan := -1
	for slot in lineup.size():
		var seat := lineup[slot]
		if taken[seat] and has_pad(seat):
			return slot
		if taken[seat] and orphan < 0:
			orphan = slot
	return orphan


## Takes every latched press, the seats' and the program's, as one set of PlayerInput.PAUSE and CONFIRM bits.
func take_presses() -> int:
	var presses := pending
	for seat in SEATS:
		presses = PlayerInput.latch(presses, seat_pending[seat])
		seat_pending[seat] = 0
	pending = 0
	return presses


func clear_presses() -> void:
	pending = 0
	for seat in SEATS:
		seat_pending[seat] = 0


## Held controls of every seat's pad together, as Held bits.
func held() -> int:
	var mask := 0
	for seat in SEATS:
		if seat_device[seat] != NO_DEVICE:
			mask |= Pads.held_of(seat_device[seat])
	return mask


# --- Inside ----------------------------------------------------------------------------------------------------------


func _attach(seat: int, device: int, guid: String) -> void:
	taken[seat] = true
	seat_device[seat] = device
	seat_guid[seat] = guid
	seat_pending[seat] = 0
	pads.note(device)


func _free(seat: int) -> void:
	taken[seat] = false
	seat_device[seat] = NO_DEVICE
	seat_guid[seat] = ""
	seat_pending[seat] = 0


func _clamp_bots() -> void:
	bots = clampi(wanted_bots, min_bots(), max_bots())


## The lowest orphan seat whose pad had this GUID ("" matches none), or with any_guid the lowest orphan seat; -1 if
## none.
func _orphan_with(guid: String, any_guid: bool = false) -> int:
	if guid.is_empty() and not any_guid:
		return -1
	for seat in SEATS:
		if is_orphan(seat) and (any_guid or seat_guid[seat] == guid):
			return seat
	return -1
