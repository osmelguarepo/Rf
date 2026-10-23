extends RefCounted
## The match ticket (docs/SPEC_ONLINE.md §16.2): what a game server asks of a client in HELLO before it lets it sit at a
## seat. This script is the interface (`verify()` is what a Verifier must answer) and the first implementation: a
## shared-secret HMAC, which a stand-in for the API (tools, tests) can issue and a server holding the same key checks.
## The real API will sign with the key of the game server that got the match; the server code does not change.
##
## Text, so it travels in HELLO as it is:
##   v1.MATCH.SEAT.STEAMID.SEED.EXPIRY.SEATS.HUMANS.SIGNATURE
## MATCH is an id of letters, digits, "-" and "_"; SEAT is the seat this ticket sits at; STEAMID is the id as text (it does
## not fit a double); SEED the match seed; EXPIRY the Unix time after which the ticket is void; SEATS the cars in the
## match; HUMANS the mask of the seats people will take (the rest are bots); SIGNATURE the HMAC-SHA256 of everything before
## it, in hex. A first valid ticket creates the room; the others join it.
##
## Dev mode (`dev`, the server's --dev): "dev." in place of "v1." and no signature, only on a server started with --dev.
## Anything that is not exactly this is refused with an `error` code, never trusted partly.

const VERSION_TAG := "v1"
const DEV_TAG := "dev"
const MAX_LENGTH := 256
const MAX_ID := 32

const ERR_FORMAT := "format"
const ERR_SIGNATURE := "bad_signature"
const ERR_EXPIRED := "expired"
const ERR_SEAT := "bad_seat"
const ERR_UNSIGNED := "unsigned_not_allowed"

## The shared secret. Empty only in dev mode.
var key: String = ""
## True accepts "dev." tickets, which carry no signature. Only a server started with --dev sets it.
var dev: bool = false


func _init(p_key: String = "", p_dev: bool = false) -> void:
	key = p_key
	dev = p_dev


## Checks a ticket at Unix time `now_unix`. Returns {"ok": true, "match_id", "seat", "steam_id", "seed", "expiry",
## "seats", "humans"} or {"ok": false, "error": ERR_*}.
func verify(ticket: String, now_unix: int) -> Dictionary:
	if ticket.length() > MAX_LENGTH:
		return _bad(ERR_FORMAT)
	var parts := ticket.split(".")
	var signed := parts.size() == 9 and parts[0] == VERSION_TAG
	if not signed:
		if parts.size() != 8 or parts[0] != DEV_TAG:
			return _bad(ERR_FORMAT)
		if not dev:
			return _bad(ERR_UNSIGNED)
	var fields := _fields(parts)
	if fields.is_empty():
		return _bad(ERR_FORMAT)
	if signed:
		var body := ".".join(parts.slice(0, 8))
		if not _same(sign_text(body), parts[8]):
			return _bad(ERR_SIGNATURE)
	var seat: int = fields["seat"]
	var seats: int = fields["seats"]
	if seats < 1 or seats > 6:
		return _bad(ERR_FORMAT)
	var humans: int = fields["humans"]
	if seat >= seats or (humans & (1 << seat)) == 0 or humans >= (1 << seats):
		return _bad(ERR_SEAT)
	var expiry: int = fields["expiry"]
	if (signed or expiry > 0) and now_unix > expiry:
		return _bad(ERR_EXPIRED)
	fields["ok"] = true
	return fields


## A signed ticket for a seat. `humans` is the mask of the human seats of the match. What the API does; here for the
## tools and the tests.
func issue(match_id: String, seat: int, steam_id: String, seed_value: int, expiry: int, seats: int, humans: int) -> String:
	var body := "%s.%s.%d.%s.%d.%d.%d.%d" % [VERSION_TAG, match_id, seat, steam_id, seed_value, expiry, seats, humans]
	return body + "." + sign_text(body)


## A dev ticket: no signature, no expiry. Only a --dev server takes it.
static func issue_dev(match_id: String, seat: int, steam_id: String, seed_value: int, seats: int, humans: int) -> String:
	return "%s.%s.%d.%s.%d.0.%d.%d" % [DEV_TAG, match_id, seat, steam_id, seed_value, seats, humans]


func sign_text(text: String) -> String:
	var crypto := Crypto.new()
	return crypto.hmac_digest(HashingContext.HASH_SHA256, key.to_utf8_buffer(), text.to_utf8_buffer()).hex_encode()


## The numbers and ids of the ticket's parts (0 to 7), or {} when any is malformed.
func _fields(parts: PackedStringArray) -> Dictionary:
	var match_id := parts[1]
	var steam_id := parts[3]
	if match_id.is_empty() or match_id.length() > MAX_ID or steam_id.is_empty() or steam_id.length() > 20:
		return {}
	for c: String in match_id:
		if not (c in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"):
			return {}
	if not steam_id.is_valid_int() or steam_id.begins_with("-") or steam_id.begins_with("+"):
		return {}
	for number: String in [parts[2], parts[4], parts[5], parts[6], parts[7]]:
		var text := number
		if not text.is_valid_int() or text.length() > 12 or text.begins_with("-") or text.begins_with("+"):
			return {}
	return {
		"match_id": match_id, "seat": parts[2].to_int(), "steam_id": steam_id, "seed": parts[4].to_int(),
		"expiry": parts[5].to_int(), "seats": parts[6].to_int(), "humans": parts[7].to_int(),
	}


## Comparison that takes as long whatever the first difference is.
static func _same(a: String, b: String) -> bool:
	if a.length() != b.length():
		return false
	var diff := 0
	for i in a.length():
		diff |= a.unicode_at(i) ^ b.unicode_at(i)
	return diff == 0


static func _bad(error: String) -> Dictionary:
	return {"ok": false, "error": error}
