extends RefCounted
## Codes of private rooms and what a client puts in HELLO to create one, join one or come back to its seat.
##
## A code is CODE_LENGTH characters from an alphabet without look-alikes (no 0/O, 1/I/L). Tickets of a private room, in
## the HELLO ticket field (no Steam ticket: private rooms give no ranking points):
##   new:NAME             make a room; the sender owns it and sits at seat 0
##   join:CODE:NAME       sit at the first free seat of the room in its lobby
##   rejoin:CODE:SEAT:SECRET   take the seat back after a lost connection, with the secret the lobby told it

const CODE_LENGTH := 6
const ALPHABET := "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
const NAME_CHARS := "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
const NAME_MIN := 3
const NAME_MAX := 8


## A new random code from `rng`.
static func generate(rng: RandomNumberGenerator) -> String:
	var out := ""
	for i in CODE_LENGTH:
		out += ALPHABET[rng.randi_range(0, ALPHABET.length() - 1)]
	return out


## The code as the rooms know it (upper case, no spaces), or "" if it is not a code.
static func normalize(text: String) -> String:
	var code := text.strip_edges().to_upper()
	if code.length() != CODE_LENGTH:
		return ""
	for c: String in code:
		if not (c in ALPHABET):
			return ""
	return code


## A name as the game shows it: upper case, only letters and digits, at most NAME_MAX; "P" and the seat number when what is
## left is shorter than NAME_MIN.
static func clean_name(text: String, seat: int) -> String:
	var out := ""
	for c: String in text.to_upper():
		if c in NAME_CHARS and out.length() < NAME_MAX:
			out += c
	return out if out.length() >= NAME_MIN else "P%d" % (seat + 1)


## The ticket that makes a room.
static func new_ticket(player_name: String) -> String:
	return "new:" + player_name


static func join_ticket(code: String, player_name: String) -> String:
	return "join:%s:%s" % [code, player_name]


static func rejoin_ticket(code: String, seat: int, secret: String) -> String:
	return "rejoin:%s:%d:%s" % [code, seat, secret]


## What a HELLO ticket asks for: {"kind": "new"|"join"|"rejoin", ...} or {} when it is none of them.
static func parse(ticket: String) -> Dictionary:
	var parts := ticket.split(":")
	match parts[0]:
		"new":
			if parts.size() == 2:
				return {"kind": "new", "name": parts[1]}
		"join":
			if parts.size() == 3 and not normalize(parts[1]).is_empty():
				return {"kind": "join", "code": normalize(parts[1]), "name": parts[2]}
		"rejoin":
			if parts.size() == 4 and not normalize(parts[1]).is_empty() and parts[2].is_valid_int():
				return {"kind": "rejoin", "code": normalize(parts[1]), "seat": parts[2].to_int(), "secret": parts[3]}
	return {}
