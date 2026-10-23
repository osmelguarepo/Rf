extends RefCounted
## The binary messages of the online game (docs/SPEC_ONLINE.md §5, with the changes of §16). Every message starts with
## `u8 type`; integers are little-endian. encode_*() builds a message; decode() reads one and returns a Dictionary with
## a "type" key, or {"error": CODE, ...} for anything it will not accept. decode() reads untrusted bytes: it never
## crashes, never logs an error and never reads outside the buffer, whatever it is given.
##
## The protocol version travels only in HELLO. A server that sees another version answers with an EVENT of kind
## EVENT_REJECT so the client can ask for an update.
##
## SteamIDs are text everywhere (§16.1): 64-bit ids do not survive a trip through a double (JSON, JavaScript).

const VERSION := 1

const HELLO := 1
const INPUT := 2
const PING := 3
const ACK_SNAPSHOT := 4
## The owner of a private room starts the match (M2); a client asks for a SNAPSHOT after a CHECKSUM mismatch (M2).
const START := 5
const SNAPSHOT_REQ := 6
const WELCOME := 16
const TICKS := 17
const SNAPSHOT := 18
const CHECKSUM := 19
const PONG := 20
const EVENT := 21
## The state of a private room before the match: its code, who sits where (M2).
const LOBBY := 22

const EVENT_DISCONNECT := 0
const EVENT_RACE_END := 1
const EVENT_MATCH_END := 2
const EVENT_REJECT := 3

## Error codes of decode().
const ERR_EMPTY := "empty"
const ERR_OVERSIZED := "oversized"
const ERR_UNKNOWN_TYPE := "unknown_type"
const ERR_TRUNCATED := "truncated"
const ERR_TRAILING := "trailing"
const ERR_VERSION := "version_mismatch"
const ERR_BAD_VALUE := "bad_value"

## Largest message either side will read or write. A snapshot is about 3.3 KB (§16), so this is generous.
const MAX_MESSAGE := 16384
const MAX_SEATS := 6
## How many earlier control bytes an INPUT repeats, to survive a lost packet on an unreliable transport.
const INPUT_HISTORY := 4
## The bits of a control byte a client may use (PlayerInput); the rest are masked (§16.1 6).
const CONTROL_MASK := 0x1F
## The control byte of a bot or an abandoned seat. A client may never send it.
const BOT_BYTE := 0xFF


static func encode_hello(game_version: String, sim_hash: int, ticket: String) -> PackedByteArray:
	var out := _start(HELLO)
	_put_u16(out, VERSION)
	_put_str8(out, game_version)
	_put_u32(out, sim_hash)
	_put_str16(out, ticket)
	return out


## `previous` holds the control bytes of the ticks before `tick`, the latest first. Missing ones are sent as 0.
static func encode_input(tick: int, control: int, previous: PackedByteArray = PackedByteArray()) -> PackedByteArray:
	var out := _start(INPUT)
	_put_u32(out, tick)
	out.append(control & 0xFF)
	for i in INPUT_HISTORY:
		out.append(previous[i] if i < previous.size() else 0)
	return out


static func encode_ping(client_time: int) -> PackedByteArray:
	var out := _start(PING)
	_put_u32(out, client_time)
	return out


static func encode_start() -> PackedByteArray:
	return _start(START)


static func encode_snapshot_req() -> PackedByteArray:
	return _start(SNAPSHOT_REQ)


static func encode_ack_snapshot(tick: int) -> PackedByteArray:
	var out := _start(ACK_SNAPSHOT)
	_put_u32(out, tick)
	return out


## `players` has one SteamID (text) per seat, "" for a bot. `config` is the serialised game configuration and tuning;
## `cfg_digest` is digest32() of what the cloned simulation must be built from (§16.1 7).
static func encode_welcome(seat: int, seed_value: int, cfg_digest: int, start_tick: int, server_tick: int,
		players: PackedStringArray, config: PackedByteArray) -> PackedByteArray:
	var out := _start(WELCOME)
	out.append(seat)
	out.append(players.size())
	_put_i64(out, seed_value)
	_put_u32(out, cfg_digest)
	_put_u32(out, start_tick)
	_put_u32(out, server_tick)
	for player in players:
		_put_str8(out, player)
	_put_u16(out, config.size())
	out.append_array(config)
	return out


## `controls` holds one byte per seat and tick, tick by tick. `margin` tells the client how many ticks before they
## were needed its latest inputs arrived (§16.1 3), clamped to -128..127.
static func encode_ticks(first_tick: int, seats: int, controls: PackedByteArray, margin: int = 0) -> PackedByteArray:
	var out := _start(TICKS)
	_put_u32(out, first_tick)
	out.append(clampi(margin, -128, 127) & 0xFF)
	out.append(seats)
	out.append_array(controls)
	return out


## `state` is a serialised Match. Returns an empty array if it would not fit in MAX_MESSAGE.
static func encode_snapshot(tick: int, state: PackedByteArray) -> PackedByteArray:
	var out := _start(SNAPSHOT)
	_put_u32(out, tick)
	out.append_array(state)
	return out if out.size() <= MAX_MESSAGE else PackedByteArray()


static func encode_checksum(tick: int, checksum: int, cfg_digest: int) -> PackedByteArray:
	var out := _start(CHECKSUM)
	_put_u32(out, tick)
	_put_u32(out, checksum)
	_put_u32(out, cfg_digest)
	return out


static func encode_pong(client_time: int, server_tick: int) -> PackedByteArray:
	var out := _start(PONG)
	_put_u32(out, client_time)
	_put_u32(out, server_tick)
	return out


static func encode_event(kind: int, seat: int, tick: int, data: PackedByteArray = PackedByteArray()) -> PackedByteArray:
	var out := _start(EVENT)
	out.append(kind)
	out.append(seat)
	_put_u32(out, tick)
	out.append_array(data)
	return out if out.size() <= MAX_MESSAGE else PackedByteArray()


## `names` has the name of the person on each seat of a private room ("" for a free one); `secret` lets this person take
## their seat back after a lost connection (ticket "rejoin:CODE:SEAT:SECRET").
static func encode_lobby(code: String, seat: int, owner: bool, secret: String, names: PackedStringArray) -> PackedByteArray:
	var out := _start(LOBBY)
	_put_str8(out, code)
	out.append(seat)
	out.append(1 if owner else 0)
	_put_str8(out, secret)
	out.append(names.size())
	for n in names:
		_put_str8(out, n)
	return out


## The message in `bytes` as a Dictionary: {"type": TYPE, ...fields}, or {"error": ERR_*, ...}.
static func decode(bytes: PackedByteArray) -> Dictionary:
	if bytes.is_empty():
		return _err(ERR_EMPTY)
	if bytes.size() > MAX_MESSAGE:
		return _err(ERR_OVERSIZED)
	var r := _Reader.new(bytes)
	var type := r.u8()
	var msg := {"type": type}
	match type:
		HELLO:
			var version := r.u16()
			if not r.ok:
				return _err(ERR_TRUNCATED)
			if version != VERSION:
				return _err(ERR_VERSION, {"version": version})
			msg["game_version"] = r.str8()
			msg["sim_hash"] = r.u32()
			msg["ticket"] = r.str16()
		INPUT:
			msg["tick"] = r.u32()
			var control := r.u8()
			var history := r.bytes(INPUT_HISTORY)
			if r.ok:
				# 0xFF is the bot's byte: a client sending it would hand its car to the AI (§16.1 6).
				if control == BOT_BYTE or history.has(BOT_BYTE):
					return _err(ERR_BAD_VALUE, {"field": "control"})
				msg["byte"] = control & CONTROL_MASK
				for i in history.size():
					history[i] &= CONTROL_MASK
				msg["history"] = history
		PING:
			msg["client_time"] = r.u32()
		ACK_SNAPSHOT:
			msg["tick"] = r.u32()
		START, SNAPSHOT_REQ:
			pass
		WELCOME:
			var seat := r.u8()
			var seats := r.u8()
			msg["seed"] = r.i64()
			msg["cfg_digest"] = r.u32()
			msg["start_tick"] = r.u32()
			msg["server_tick"] = r.u32()
			if r.ok and (seats < 1 or seats > MAX_SEATS or seat >= seats):
				return _err(ERR_BAD_VALUE, {"field": "seat"})
			var players := PackedStringArray()
			for i in seats:
				players.append(r.str8())
			msg["seat"] = seat
			msg["seats"] = seats
			msg["players"] = players
			msg["config"] = r.bytes(r.u16())
		TICKS:
			msg["first_tick"] = r.u32()
			var margin := r.u8()
			msg["margin"] = margin - 256 if margin > 127 else margin
			var seats := r.u8()
			var controls := r.rest()
			if r.ok:
				if seats < 1 or seats > MAX_SEATS or controls.is_empty() or controls.size() % seats != 0:
					return _err(ERR_BAD_VALUE, {"field": "controls"})
				msg["seats"] = seats
				msg["controls"] = controls
				msg["count"] = floori(float(controls.size()) / float(seats))
		SNAPSHOT:
			msg["tick"] = r.u32()
			msg["state"] = r.rest()
		CHECKSUM:
			msg["tick"] = r.u32()
			msg["checksum"] = r.u32()
			msg["cfg_digest"] = r.u32()
		PONG:
			msg["client_time"] = r.u32()
			msg["server_tick"] = r.u32()
		LOBBY:
			msg["code"] = r.str8()
			msg["seat"] = r.u8()
			msg["owner"] = r.u8() != 0
			msg["secret"] = r.str8()
			var count := r.u8()
			if r.ok and count > MAX_SEATS:
				return _err(ERR_BAD_VALUE, {"field": "names"})
			var names := PackedStringArray()
			for i in count:
				names.append(r.str8())
			msg["names"] = names
		EVENT:
			var kind := r.u8()
			msg["seat"] = r.u8()
			msg["tick"] = r.u32()
			msg["data"] = r.rest()
			if r.ok and kind > EVENT_REJECT:
				return _err(ERR_BAD_VALUE, {"field": "kind"})
			msg["kind"] = kind
		_:
			return _err(ERR_UNKNOWN_TYPE, {"value": type})
	if r.bad_text:
		return _err(ERR_BAD_VALUE, {"field": "text"})
	if not r.ok:
		return _err(ERR_TRUNCATED)
	if not r.at_end():
		return _err(ERR_TRAILING)
	return msg


static func is_error(msg: Dictionary) -> bool:
	return msg.has("error")


## FNV-1a, 32 bits: the digest of the configuration in WELCOME and CHECKSUM.
static func digest32(bytes: PackedByteArray) -> int:
	var h: int = 0x811C9DC5
	for b in bytes:
		h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF
	return h


static func _err(code: String, extra: Dictionary = {}) -> Dictionary:
	var out := {"error": code}
	out.merge(extra)
	return out


static func _start(type: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.append(type)
	return out


static func _put_u16(out: PackedByteArray, value: int) -> void:
	var at := out.size()
	out.resize(at + 2)
	out.encode_u16(at, value)


static func _put_u32(out: PackedByteArray, value: int) -> void:
	var at := out.size()
	out.resize(at + 4)
	out.encode_u32(at, value)


static func _put_i64(out: PackedByteArray, value: int) -> void:
	var at := out.size()
	out.resize(at + 8)
	out.encode_s64(at, value)


## Text with a one-byte length. Longer text is cut: callers keep it short (ids, versions).
static func _put_str8(out: PackedByteArray, text: String) -> void:
	var raw := text.to_ascii_buffer().slice(0, 255)
	out.append(raw.size())
	out.append_array(raw)


static func _put_str16(out: PackedByteArray, text: String) -> void:
	var raw := text.to_ascii_buffer().slice(0, 65535)
	_put_u16(out, raw.size())
	out.append_array(raw)


## Bounds-checked reading: past the end every read gives 0 or empty and clears `ok`.
class _Reader:
	var data: PackedByteArray
	var pos: int = 0
	var ok: bool = true
	var bad_text: bool = false

	func _init(bytes: PackedByteArray) -> void:
		data = bytes

	func at_end() -> bool:
		return pos >= data.size()

	func _take(n: int) -> bool:
		if not ok or n < 0 or pos + n > data.size():
			ok = false
			return false
		return true

	func u8() -> int:
		if not _take(1):
			return 0
		pos += 1
		return data[pos - 1]

	func u16() -> int:
		if not _take(2):
			return 0
		pos += 2
		return data.decode_u16(pos - 2)

	func u32() -> int:
		if not _take(4):
			return 0
		pos += 4
		return data.decode_u32(pos - 4)

	func i64() -> int:
		if not _take(8):
			return 0
		pos += 8
		return data.decode_s64(pos - 8)

	func bytes(n: int) -> PackedByteArray:
		if not _take(n):
			return PackedByteArray()
		pos += n
		return data.slice(pos - n, pos)

	func rest() -> PackedByteArray:
		if not ok:
			return PackedByteArray()
		var out := data.slice(pos)
		pos = data.size()
		return out

	func str8() -> String:
		return _text(bytes(u8()))

	func str16() -> String:
		return _text(bytes(u16()))

	# Text on the wire is printable ASCII (ids, versions, tickets). Anything else is garbage, and turning it into a
	# String would make the engine log UTF-8 errors, which decode() promises never to do.
	func _text(raw: PackedByteArray) -> String:
		for b in raw:
			if b < 0x20 or b > 0x7E:
				bad_text = true
				ok = false
				return ""
		return raw.get_string_from_ascii()
