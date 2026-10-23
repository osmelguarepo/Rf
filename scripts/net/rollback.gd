extends RefCounted
## The two states of the online client (docs/SPEC_ONLINE.md §16.1 2). Nothing here knows the network.
##
## - `confirmed` follows the server's canonical stream, tick by tick, and never goes back: it steps only on bytes the server
##   decided, so it is exactly the server's match (a lagging copy of it).
## - `predicted` is what the player sees: the confirmed state advanced to now with the player's own inputs and, for every
##   other seat, the last byte the server confirmed for it (a button held stays held; the presses of a round start are not
##   guessed). It is rebuilt from a copy of `confirmed` and the unconfirmed ticks played again whenever a confirmed tick turns
##   out different from what predicted used, or a remote seat's confirmed byte changes ("rollback"), and only then: with
##   nothing new the prediction just plays on. always_rebuild rebuilds every frame instead, which gives exactly the same state
##   at a higher cost (the tests compare them).
## - More than max_predict ticks ahead of the confirmed state the prediction freezes: it waits instead of guessing further.
##
## What it measures, for the gates of M2 (§16.7): the depth of every rebuild (ticks played again), its time, and the
## correction (px a car moves when the prediction is replaced by the new one).

const Match := preload("res://scripts/sim/match.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")

## The farthest the predicted state runs ahead of the confirmed one, in ticks (1 s).
const MAX_PREDICT := 60
## What a remote seat's byte keeps of its last confirmed value: the held bits. The presses are not repeated.
const HELD_BITS := 0x1F
## How many own inputs are remembered behind the confirmed tick (INPUT repeats the last four).
const OWN_KEEP := 16

var confirmed: Match = null
var predicted: Match = null
var seats: int = 0
var own_seat: int = 0
var start_tick: int = 0
## The next tick the confirmed state will take: ticks before it are confirmed.
var confirmed_tick: int = 0
## The next tick the predicted state will take.
var predicted_tick: int = 0
var max_predict: int = MAX_PREDICT
var always_rebuild: bool = false
## Called with the predicted match after a tick is predicted for the first time (never when a rebuild plays it again): the
## sounds follow it, so a rollback does not repeat them.
var on_predicted_tick: Callable = Callable()
## Called with (tick, confirmed match) after each confirmed tick: the state is the match after `tick` ticks. Tools and tests compare it with the server's.
var on_confirmed: Callable = Callable()

## Rebuilds so far, the ticks each one played again, the microseconds each took, and the biggest shift of any car (px) and the
## shift of the player's own car at each.
var rebuilds: int = 0
var depths: Array[int] = []
var rebuild_us: Array[int] = []
var corrections: Array[float] = []
var own_corrections: Array[float] = []
## Per seat, the shift (px) the last rebuild gave the car: old position minus new, for the view to ease out.
var last_shift: Dictionary = {}

var _own: Dictionary = {}
var _own_first: int = PlayerInput.NONE
var _own_last: int = PlayerInput.NONE
var _has_own: bool = false
var _first_tick: int = 0
var _known: PackedByteArray = PackedByteArray()
var _used: Dictionary = {}
var _fired: int = 0
var _dirty: bool = false


## Starts from `initial` (the match at `p_start_tick`, when the first step is taken).
func setup(initial: Match, p_start_tick: int, p_seats: int, p_own_seat: int) -> void:
	confirmed = initial
	predicted = initial.clone()
	seats = p_seats
	own_seat = p_own_seat
	start_tick = p_start_tick
	confirmed_tick = p_start_tick
	predicted_tick = p_start_tick
	_fired = p_start_tick
	_known.resize(p_seats)
	for i in p_seats:
		_known[i] = PlayerInput.NONE if initial.world.players[i].human != 0 else PlayerInput.BOT
	_used.clear()
	_dirty = false


## The state of the match at `tick` from the server (a SNAPSHOT): the confirmed state becomes it and the prediction starts over.
func reset_confirmed(m: Match, tick: int) -> void:
	confirmed = m
	confirmed_tick = tick
	predicted = m.clone()
	predicted_tick = tick
	_fired = maxi(_fired, tick)
	_used.clear()
	_dirty = false


## The player's own control for a tick.
func set_own(tick: int, byte: int) -> void:
	if not _has_own:
		_own_first = byte
		_first_tick = tick
		_has_own = true
	_own[tick] = byte
	_own_last = byte
	var drop := tick - OWN_KEEP - max_predict - 8
	if _own.has(drop):
		_own.erase(drop)


## The player's own control for a tick, as sent: the first one for ticks before the first.
func own_byte(tick: int) -> int:
	if _own.has(tick):
		return _own[tick]
	return _own_first if tick < _first_tick else _own_last


## The server confirms the next tick: `bytes` are the seats' bytes for tick `confirmed_tick`.
func confirm(bytes: PackedByteArray) -> void:
	var tick := confirmed_tick
	confirmed.step(bytes, true)
	confirmed_tick += 1
	if on_confirmed.is_valid():
		on_confirmed.call(confirmed_tick, confirmed)
	# A remote seat whose confirmed byte differs from the last one changes what the ticks still to come are predicted with.
	var changed := false
	for s in seats:
		var b := bytes[s]
		var held := b if b == PlayerInput.BOT else b & HELD_BITS
		changed = changed or (s != own_seat and held != _known[s])
		_known[s] = held
	if tick < predicted_tick:
		var used: PackedByteArray = _used.get(tick, PackedByteArray())
		if used != bytes or (changed and predicted_tick > confirmed_tick):
			_dirty = true
		_used.erase(tick)
	else:
		# The prediction is behind what the server has decided (a freeze, or it has not run yet): start from the confirmed copy.
		_dirty = true


## Plays the predicted state forward to `target_tick` (never beyond max_predict ticks past the confirmed one), after
## replacing it with a rebuild if a confirmed tick differed from what it had used.
func advance(target_tick: int) -> void:
	if always_rebuild and predicted_tick > confirmed_tick:
		_dirty = true
	if _dirty:
		_rebuild()
	var goal := mini(target_tick, confirmed_tick + max_predict)
	while predicted_tick < goal:
		var bytes := _compose(predicted_tick)
		_used[predicted_tick] = bytes
		if predicted_tick >= start_tick:
			predicted.step(bytes, true)
		if predicted_tick >= _fired:
			_fired = predicted_tick + 1
			if on_predicted_tick.is_valid():
				on_predicted_tick.call(predicted)
		predicted_tick += 1


## How far ahead of the confirmed state the prediction is.
func lead() -> int:
	return predicted_tick - confirmed_tick


func _compose(tick: int) -> PackedByteArray:
	var bytes := _known.duplicate()
	bytes[own_seat] = _own.get(tick, _own_last)
	return bytes


func _rebuild() -> void:
	var started := Time.get_ticks_usec()
	var old := predicted
	var old_tick := predicted_tick
	_dirty = false
	var fresh := confirmed.clone()
	var tick := confirmed_tick
	while tick < old_tick:
		var bytes := _compose(tick)
		_used[tick] = bytes
		if tick >= start_tick:
			fresh.step(bytes, true)
		tick += 1
	predicted = fresh
	predicted_tick = maxi(old_tick, confirmed_tick)
	if old_tick <= confirmed_tick:
		# Nothing was played ahead: no depth, no correction to measure.
		last_shift = {}
		return
	rebuilds += 1
	depths.append(old_tick - confirmed_tick)
	var biggest := 0.0
	var own := 0.0
	var shift := {}
	if old.round_number == fresh.round_number and old.phase == fresh.phase:
		for i in seats:
			var a := old.world.players[i]
			var b := fresh.world.players[i]
			var delta := Vector2(a.x - b.x, a.y_world - b.y_world)
			shift[i] = delta
			biggest = maxf(biggest, delta.length())
			if i == own_seat:
				own = delta.length()
	corrections.append(biggest)
	own_corrections.append(own)
	last_shift = shift
	rebuild_us.append(Time.get_ticks_usec() - started)
