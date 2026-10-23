extends RefCounted
## The match ticket the API issues (backend/docs/TICKET.md, version 1, byte for byte; docs/SPEC_ONLINE.md §16.2): what a game
## server checks in HELLO before it lets a client sit at a seat. It replaces the stand-in HMAC ticket of ticket.gd for matches
## from the API (ticket.gd stays for development tools and tests).
##
##   ticket  = base64url(payload || mac), no padding, decoded strictly
##   mac     = HMAC-SHA256(key, payload), key = the server's 32 bytes (the hex of its key, decoded)
##   payload = version u8 (1), flags u8 (bit 0 guest), seat u8 (0-5), seed u64 (< 2^63), expires u64 (unix s, < 2^63),
##             then five strings of one length byte and ASCII: server_id, match_id, player_id, steam_id, name
## All integers big endian. Ids are text: they do not fit a double. A ticket says nothing about who else is in the match, so
## the result has `seats` = 6 (the rest are bots) and `humans` = only this seat, with `open` true: the room learns the other
## humans as their tickets arrive (host.gd, room.gd).
##
## verify() returns {"ok": true, ...fields} or {"ok": false, "error": ERR_*}; an expired ticket whose signature is good
## also carries its `fields`, which the host uses to let a seat come back after a lost connection.

const Ticket := preload("res://scripts/net/ticket.gd")

const VERSION := 1
const FLAG_GUEST := 1
const MAX_SEAT := 5
const SEATS := 6
const MAC_BYTES := 32
## Fixed part of the payload (version, flags, seat, seed, expires) and the five length bytes.
const MIN_PAYLOAD := 19 + 5
const MAX_TICKET_CHARS := 16384
const B64 := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

const ERR_FORMAT := Ticket.ERR_FORMAT
const ERR_SIGNATURE := Ticket.ERR_SIGNATURE
const ERR_EXPIRED := Ticket.ERR_EXPIRED
const ERR_SERVER := "wrong_server"

## The server's key, the 32 decoded bytes.
var key: PackedByteArray = PackedByteArray()
## This server's id: a ticket for another server is refused. Empty accepts any (tests).
var server_id: String = ""


func _init(p_key_hex: String = "", p_server_id: String = "") -> void:
	key = p_key_hex.hex_decode()
	server_id = p_server_id


## A ticket checked at Unix time `now_unix`.
func verify(ticket: String, now_unix: int) -> Dictionary:
	var raw := base64url_decode(ticket)
	if raw.size() < MIN_PAYLOAD + MAC_BYTES:
		return _bad(ERR_FORMAT)
	var payload := raw.slice(0, raw.size() - MAC_BYTES)
	var mac := raw.slice(raw.size() - MAC_BYTES)
	var fields := parse_payload(payload)
	if fields.is_empty():
		return _bad(ERR_FORMAT)
	if key.is_empty() or not same_bytes(hmac(key, payload), mac):
		return _bad(ERR_SIGNATURE)
	if not server_id.is_empty() and fields["server_id"] != server_id:
		return {"ok": false, "error": ERR_SERVER, "fields": fields}
	if now_unix > int(fields["expires"]):
		return {"ok": false, "error": ERR_EXPIRED, "fields": fields}
	return accepted(fields)


## The verified fields, plus what the host and the room read.
static func accepted(fields: Dictionary) -> Dictionary:
	var out := fields.duplicate()
	out["ok"] = true
	out["seats"] = SEATS
	out["humans"] = 1 << int(fields["seat"])
	out["open"] = true
	out["expiry"] = fields["expires"]
	return out


## Builds a ticket (what the API does; for tests and tools).
static func issue(p_key: PackedByteArray, fields: Dictionary) -> String:
	var payload := build_payload(fields)
	return base64url_encode(payload + hmac(p_key, payload))


static func hmac(p_key: PackedByteArray, payload: PackedByteArray) -> PackedByteArray:
	return Crypto.new().hmac_digest(HashingContext.HASH_SHA256, p_key, payload)


## The payload of fields {guest, seat, seed (int or decimal text), expires, server_id, match_id, player_id, steam_id, name}.
static func build_payload(fields: Dictionary) -> PackedByteArray:
	var out := PackedByteArray()
	out.append(VERSION)
	out.append(FLAG_GUEST if bool(fields.get("guest", false)) else 0)
	out.append(int(fields["seat"]))
	_put_u64(out, int(str(fields["seed"])))
	_put_u64(out, int(str(fields["expires"])))
	for name: String in ["server_id", "match_id", "player_id", "steam_id", "name"]:
		var text: PackedByteArray = str(fields.get(name, "")).to_ascii_buffer()
		out.append(text.size())
		out.append_array(text)
	return out


## The fields of a payload, or {} when it is not exactly the format.
static func parse_payload(payload: PackedByteArray) -> Dictionary:
	if payload.size() < MIN_PAYLOAD or payload[0] != VERSION:
		return {}
	var flags := payload[1]
	if flags & ~FLAG_GUEST != 0:
		return {}
	var seat := payload[2]
	if seat > MAX_SEAT:
		return {}
	if payload[3] & 0x80 != 0 or payload[11] & 0x80 != 0:
		return {}
	var seed_value := _get_u64(payload, 3)
	var expires := _get_u64(payload, 11)
	var at := 19
	var texts: Array[String] = []
	for i in 5:
		if at >= payload.size():
			return {}
		var n := payload[at]
		at += 1
		if n > 64 or at + n > payload.size():
			return {}
		var chunk := payload.slice(at, at + n)
		for b in chunk:
			if b >= 0x80:
				return {}
		var text := chunk.get_string_from_ascii()
		texts.append(text)
		at += n
	if at != payload.size():
		return {}
	var guest := (flags & FLAG_GUEST) != 0
	var server_id := texts[0]
	var match_id := texts[1]
	var player_id := texts[2]
	var steam_id := texts[3]
	var display := texts[4]
	if server_id.is_empty() or not _printable(server_id) or not _digits(match_id, 1, 19) or not _digits(player_id, 1, 19):
		return {}
	if guest != steam_id.is_empty() or (not guest and not _digits(steam_id, 17, 17)):
		return {}
	if display.length() > 8 or not _name_chars(display):
		return {}
	return {
		"guest": guest, "seat": seat, "seed": seed_value, "expires": expires, "server_id": server_id, "match_id": match_id,
		"player_id": player_id, "steam_id": steam_id, "name": display,
	}


## Strict base64url without padding; an empty PackedByteArray for anything else.
static func base64url_decode(text: String) -> PackedByteArray:
	var out := PackedByteArray()
	var n := text.length()
	if n == 0 or n > MAX_TICKET_CHARS or n % 4 == 1:
		return out
	var bits := 0
	var count := 0
	for c in text:
		var v := B64.find(c)
		if v < 0:
			return PackedByteArray()
		bits = (bits << 6) | v
		count += 6
		if count >= 8:
			count -= 8
			out.append((bits >> count) & 0xFF)
			bits &= (1 << count) - 1
	if bits != 0:
		return PackedByteArray()
	return out


static func base64url_encode(bytes: PackedByteArray) -> String:
	var out := ""
	var bits := 0
	var count := 0
	for b in bytes:
		bits = (bits << 8) | b
		count += 8
		while count >= 6:
			count -= 6
			out += B64[(bits >> count) & 63]
		bits &= (1 << count) - 1
	if count > 0:
		out += B64[(bits << (6 - count)) & 63]
	return out


## Comparison that takes as long whatever the first difference is.
static func same_bytes(a: PackedByteArray, b: PackedByteArray) -> bool:
	if a.size() != b.size():
		return false
	var diff := 0
	for i in a.size():
		diff |= a[i] ^ b[i]
	return diff == 0


static func _get_u64(bytes: PackedByteArray, at: int) -> int:
	var v := 0
	for i in 8:
		v = (v << 8) | bytes[at + i]
	return v


static func _put_u64(out: PackedByteArray, value: int) -> void:
	for i in range(7, -1, -1):
		out.append((value >> (i * 8)) & 0xFF)


static func _printable(text: String) -> bool:
	for c in text:
		var code := c.unicode_at(0)
		if code < 0x21 or code > 0x7e:
			return false
	return true


static func _digits(text: String, low: int, high: int) -> bool:
	if text.length() < low or text.length() > high:
		return false
	for c in text:
		if c < "0" or c > "9":
			return false
	return true


static func _name_chars(text: String) -> bool:
	for c in text:
		if not ((c >= "A" and c <= "Z") or (c >= "0" and c <= "9")):
			return false
	return true


static func _bad(error: String) -> Dictionary:
	return {"ok": false, "error": error}
