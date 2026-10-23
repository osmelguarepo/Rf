extends RefCounted
## What server and clients must agree on to run the same simulation (docs/SPEC_ONLINE.md §16.1 7): the game's Config
## plus the developer's tuning, how it travels in WELCOME, the digest that WELCOME and CHECKSUM carry, and the hash of the
## simulation that HELLO carries. A Match snapshot only serialises `cfg.profile`, so the rest of the rules has to be built
## the same on both ends: this is where it is.

const Config := preload("res://scripts/sim/config.gd")
const Match := preload("res://scripts/sim/match.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")
const Tuning := preload("res://scripts/app/tuning.gd")
const Protocol := preload("res://scripts/net/protocol.gd")

## Sent in HELLO. The server only logs it: what has to match is sim_hash().
const GAME_VERSION := "0.2.0"
## Ticks and seed of the fixed run that sim_hash() takes its checksum from.
const HASH_TICKS := 90
const HASH_SEED := 1


## The tuning keys that belong to the simulation (time_scale is the app's).
static func keys() -> PackedStringArray:
	var out := PackedStringArray()
	for field: Dictionary in Tuning.FIELDS:
		var key: String = field["key"]
		if key != Tuning.TIME_SCALE:
			out.append(key)
	return out


## The changed tuning values (key -> float) as WELCOME carries them. Unknown keys are left out.
static func encode(overrides: Dictionary = {}) -> PackedByteArray:
	var clean := {}
	var known := keys()
	for key: Variant in overrides:
		if key is String and known.has(key) and (overrides[key] is float or overrides[key] is int):
			clean[key] = float(overrides[key])
	return var_to_bytes(clean)


## The Config the bytes describe: the game's rules with the overrides applied (kept inside the dashboard's ranges), or
## null when the bytes are not what encode() makes.
static func build(bytes: PackedByteArray) -> Config:
	var cfg := Config.game()
	if bytes.is_empty():
		return cfg
	var parsed: Variant = bytes_to_var(bytes)
	if not (parsed is Dictionary):
		return null
	var known := keys()
	for key: Variant in parsed:
		if not (key is String) or not known.has(key) or not (parsed[key] is float):
			return null
		var field := Tuning.field_of(key)
		var value := clampf(float(parsed[key]), float(field["min"]), float(field["max"]))
		cfg.set(key, roundi(value) if typeof(cfg.get(key)) == TYPE_INT else value)
	return cfg


## 32 bits that follow every rule a Config adds to the snapshot's profile.
static func digest(cfg: Config) -> int:
	var values: Array = []
	for key in keys():
		values.append(cfg.get(key))
	return Protocol.digest32(var_to_bytes(values))


## A match as server and clients build it. (They step it with Match.step(bytes, true): online, a seat can be taken back.)
static func new_match(cfg: Config, seed_value: int, seats: int, humans: int) -> Match:
	return Match.create(cfg, seed_value, seats, humans)


## The hash of the simulation (§14 8): the checksum of a fixed run, so a client with other rules, or another build of the
## simulation that behaves differently, is turned away before it can desync anyone.
static func sim_hash() -> int:
	var m := Match.create(Config.game(), HASH_SEED, 3, 0b001)
	var held := PackedByteArray([PlayerInput.encode(true, false, 1, true), PlayerInput.BOT, PlayerInput.BOT])
	for i in HASH_TICKS:
		held[0] = PlayerInput.encode(true, false, floori(i / 20.0) % 3 - 1, i % 7 == 0)
		m.step(held)
	return Protocol.digest32(m.checksum().to_ascii_buffer())


## The checksum of a match as CHECKSUM carries it: the first 32 bits of Match.checksum().
static func checksum32(m: Match) -> int:
	return m.checksum().substr(0, 8).hex_to_int()
