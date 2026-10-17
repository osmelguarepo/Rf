extends "res://tests/test_case.gd"
## The complete state (docs/GODOT_PLAN.md §3): to_array() / from_array() cover every field, clone() is deep, and
## checksum() = SHA-256 of var_to_bytes(to_array()). A restored or cloned world continues bit for bit.

const Config := preload("res://scripts/sim/config.gd")
const Rng := preload("res://scripts/sim/rng.gd")
const Car := preload("res://scripts/sim/car.gd")
const Traffic := preload("res://scripts/sim/traffic.gd")
const World := preload("res://scripts/sim/world.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")
const Bot := preload("res://scripts/sim/bot.gd")
const H := preload("res://tests/sim_helpers.gd")

## World fields that to_array() writes as nested arrays rather than as SCALARS.
const COMPOSITE_FIELDS := ["cfg", "rng", "spawner", "players", "traffic", "bots"]


## Plan §6: restore at tick 600, run 600 more and get the same checksum as the run that never stopped. Also through
## var_to_bytes() and back, as a saved game or a network snapshot would travel, and through clone().
func test_restore_midway_same_checksum() -> void:
	for cfg: Config in [Config.standard(), Config.phaser()]:
		var w := World.new(cfg, 20261015)
		for tick in 600:
			w.step(_input(tick))
		var saved := w.to_array()
		var travelled: Array = bytes_to_var(var_to_bytes(saved))
		var copy := w.clone()
		for tick in range(600, 1200):
			w.step(_input(tick))
		var restored := World.from_array(cfg, saved)
		var unpacked := World.from_array(cfg, travelled)
		for tick in range(600, 1200):
			restored.step(_input(tick))
			unpacked.step(_input(tick))
			copy.step(_input(tick))
		var label := "profile %d" % cfg.profile
		assert_eq(restored.checksum(), w.checksum(), label)
		assert_eq(unpacked.checksum(), w.checksum(), label + ", through var_to_bytes")
		assert_eq(copy.checksum(), w.checksum(), label + ", through clone()")
		assert_eq(w.tick, 1200)
		assert_gt(w.spawner.next_id, 3, label + ": traffic spawned")


## Every script variable of World is a SCALARS entry or one of the composite fields, and the per-object arrays
## have one entry per field, so a field added later cannot be left out of to_array() unnoticed.
func test_to_array_covers_every_field() -> void:
	var w := World.new(Config.standard(), 3)
	var world_fields := _script_fields(w)
	var listed: Array = World.SCALARS.duplicate()
	listed.append_array(COMPOSITE_FIELDS)
	assert_eq(_sorted(world_fields), _sorted(listed), "World fields")
	assert_eq(w.to_array().size(), 3 + World.SCALARS.size() + 4, "FORMAT, profile, rng, SCALARS, spawner, seats, traffic, bots")
	var car := Car.new()
	assert_eq(car.to_array().size(), _script_fields(car).size(), "Car fields")
	assert_eq(_script_fields(car.rng), ["state"], "a seat's own Rng: one u32")
	var bot := Bot.new(9)
	assert_eq(bot.to_array().size(), _script_fields(bot).size(), "Bot fields")
	assert_eq(_script_fields(bot.rng), ["state"], "a bot's own Rng: one u32")
	var object := Traffic.new()
	assert_eq(object.to_array().size(), _script_fields(object).size(), "Traffic fields")
	assert_eq(w.spawner.to_array().size(), _script_fields(w.spawner).size(), "Spawner fields")
	assert_eq(_script_fields(w.rng), ["state"], "Rng: one u32")


## Each numeric field, set to a value no game would give it, survives to_array() / from_array(), and changing any one
## of them changes the checksum. In a single-player world and in a versus world, whose bots add their fields and the
## bytes each bot has decided and not yet sent.
func test_every_field_round_trips_and_moves_the_checksum() -> void:
	var cfg := Config.standard()
	for w: World in [World.new(cfg, 5, 2), World.versus(cfg, 5, 3, 0b011)]:
		var label := "mode %d" % w.mode
		H.in_lane(w, Config.KIND_RED, 4, 100.0, 90.0)
		H.in_lane(w, Config.KIND_OIL, 1, 50.0)
		var targets := _numeric_targets(w)
		var next_value := 7
		for target: Array in targets:
			var owner: Object = target[0]
			var field: String = target[1]
			next_value += 1
			owner.set(field, next_value if typeof(owner.get(field)) == TYPE_INT else float(next_value) + 0.25)
		for b: Bot in w.bots:
			for i in b.pending.size():
				next_value += 1
				b.pending[i] = next_value
		var back := World.from_array(cfg, w.to_array())
		assert_eq(_dump(back), _dump(w), label + ": every field after the round trip")
		assert_eq(back.checksum(), w.checksum(), label)
		var unchanged := 0
		for target: Array in targets:
			var copy := w.clone()
			var owner_in_copy: Object = _same_owner(copy, w, target[0])
			var field: String = target[1]
			var value: Variant = owner_in_copy.get(field)
			owner_in_copy.set(field, value + 1 if typeof(value) == TYPE_INT else value + 0.5)
			if copy.checksum() == w.checksum():
				unchanged += 1
		for slot in w.bots.size():
			for i in w.bots[slot].pending.size():
				var copy := w.clone()
				copy.bots[slot].pending[i] += 1
				if copy.checksum() == w.checksum():
					unchanged += 1
		assert_eq(unchanged, 0, label + ": fields that do not change the checksum")
		assert_gt(targets.size(), 40, label + ": numeric fields checked")
		if w.mode == World.MODE_VERSUS:
			assert_eq(w.bots.size(), 3, "a bot for each seat")
			assert_gt(w.bots[0].pending.size(), 0, "bytes waiting in each bot")


func test_checksum_is_sha256_of_var_to_bytes() -> void:
	var w := World.new(Config.standard(), 11)
	H.run(w, H.ACCEL, 30)
	var checksum := w.checksum()
	assert_eq(checksum, var_to_bytes(w.to_array()).hex_encode().sha256_text())
	assert_eq(checksum.length(), 64)
	assert_eq(w.clone().checksum(), checksum)


func test_clone_is_deep() -> void:
	var w := World.new(Config.standard(), 12)
	H.run(w, H.ACCEL, 400)
	H.in_lane(w, Config.KIND_YELLOW, 0, 100.0, 50.0)
	var before := w.checksum()
	var copy := w.clone()
	copy.player().x += 3.0
	copy.traffic[0].passed_mask = 3
	copy.spawner.car_gap += 1.0
	copy.rng.next()
	copy.traffic.append(Traffic.new())
	H.run(copy, H.ACCEL_HIGH, 30)
	assert_eq(w.checksum(), before, "the original is untouched")


## to_array() starts with the layout version, the profile (from_array() checks both) and the RNG state.
func test_to_array_starts_with_format_profile_and_rng() -> void:
	var w := World.new(Config.phaser(), 1)
	var a := w.to_array()
	assert_eq(a[0], World.FORMAT)
	assert_eq(a[1], Config.PROFILE_PHASER)
	assert_eq(a[2], w.rng.state)
	assert_eq(a[3], 1, "game_seed, the first of SCALARS")
	assert_eq(World.from_array(Config.phaser(), a).checksum(), w.checksum())


# --- helpers ---------------------------------------------------------------------------------------------------------


## A fixed script of inputs: throttle, high gear when fast, steering that weaves, a pause, braking.
static func _input(tick: int) -> PackedByteArray:
	if tick == 300 or tick == 360:
		return PackedByteArray([PlayerInput.PAUSE | PlayerInput.STEER_NONE])
	var steer: int = [0, -1, 0, 1][floori(tick / 45.0) % 4]
	var brake := tick % 500 > 470
	return PackedByteArray([PlayerInput.encode(true, brake, steer, tick > 240)])


## Names of an object's script variables.
static func _script_fields(object: Object) -> Array:
	var names: Array = []
	for property: Dictionary in object.get_property_list():
		if (int(property["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE) != 0:
			names.append(property["name"])
	return names


static func _sorted(values: Array) -> Array:
	var out := values.duplicate()
	out.sort()
	return out


## [owner, field] for every int and float field of the world, its RNG, spawner, seats (and each seat's own RNG
## stream), traffic and bots (and each bot's own RNG stream).
static func _numeric_targets(w: World) -> Array:
	var owners: Array = [w, w.rng, w.spawner]
	owners.append_array(w.players)
	for p: Car in w.players:
		owners.append(p.rng)
	owners.append_array(w.traffic)
	owners.append_array(w.bots)
	for b: Bot in w.bots:
		owners.append(b.rng)
	var targets: Array = []
	for owner: Object in owners:
		for field: String in _script_fields(owner):
			var kind := typeof(owner.get(field))
			if kind == TYPE_INT or kind == TYPE_FLOAT:
				targets.append([owner, field])
	return targets


## The object in `copy` that plays the part `original_owner` plays in `original`.
static func _same_owner(copy: World, original: World, original_owner: Object) -> Object:
	if original_owner == original:
		return copy
	if original_owner == original.rng:
		return copy.rng
	if original_owner == original.spawner:
		return copy.spawner
	for i in original.players.size():
		if original.players[i] == original_owner:
			return copy.players[i]
		if original.players[i].rng == original_owner:
			return copy.players[i].rng
	for i in original.traffic.size():
		if original.traffic[i] == original_owner:
			return copy.traffic[i]
	for i in original.bots.size():
		if original.bots[i] == original_owner:
			return copy.bots[i]
		if original.bots[i].rng == original_owner:
			return copy.bots[i].rng
	return null


## Every script variable of the world and of everything it holds, by path.
static func _dump(w: World) -> Dictionary:
	var out := {}
	var owners := {"world": w, "rng": w.rng, "spawner": w.spawner}
	for i in w.players.size():
		owners["seat%d" % i] = w.players[i]
		owners["seat%d.rng" % i] = w.players[i].rng
	for i in w.traffic.size():
		owners["traffic%d" % i] = w.traffic[i]
	for i in w.bots.size():
		owners["bot%d" % i] = w.bots[i]
		owners["bot%d.rng" % i] = w.bots[i].rng
		out["bot%d.pending" % i] = w.bots[i].pending.duplicate()
	for name: String in owners:
		var owner: Object = owners[name]
		for field: String in _script_fields(owner):
			var value: Variant = owner.get(field)
			if typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT:
				out["%s.%s" % [name, field]] = value
	out["counts"] = [w.players.size(), w.traffic.size(), w.bots.size(), w.cfg.profile]
	return out
