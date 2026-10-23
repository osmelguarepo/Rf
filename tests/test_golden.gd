extends "res://tests/test_case.gd"
## Golden traces: the Godot simulation against the Phaser rules (docs/GODOT_PLAN.md §6).
##
## tests/golden/phaser_golden.json was written by tools/gen_golden/phaser_golden.test.ts, which ran the TypeScript
## rules of commit 0a0841f. Doubles are 16 hex digits (IEEE-754, little-endian) and RNG outputs are u32, so
## "bit-exact" here compares hex strings and integers, never decimal text. tools/gen_golden/README.md describes
## every section of the file.

const Config := preload("res://scripts/sim/config.gd")
const Rng := preload("res://scripts/sim/rng.gd")
const Car := preload("res://scripts/sim/car.gd")
const Traffic := preload("res://scripts/sim/traffic.gd")
const World := preload("res://scripts/sim/world.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")

const GOLDEN_PATH := "res://tests/golden/phaser_golden.json"
const FNV_OFFSET := 2166136261
const FNV_PRIME := 16777619
const U32_MASK := 0xFFFFFFFF
## The port keeps world y and rebuilds a traffic object's screen y from the camera, so that one value is only
## compared within this tolerance (px). Everything else in the world trace is exact.
const SCREEN_Y_TOLERANCE := 1e-8
## no_traffic_60s in the six-lane profile: world y against Phaser's distance x K.
const DISTANCE_TOLERANCE := 1e-9
## Columns of world_phaser that must match at every tick.
const EXACT_COLUMNS := [
	"phase", "stage", "x", "speed", "fuel", "distance", "score", "events", "traffic_count", "next_id",
	"traffic_hash", "player_hash"
]

var _golden: Dictionary = {}
## The world replay, computed once for the file by _world_replay().
var _replay: Dictionary = {}


func before_all() -> void:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(GOLDEN_PATH))
	if parsed is Dictionary:
		_golden = parsed


func test_golden_file_uses_the_ports_codes() -> void:
	assert_eq(int(_golden.get("format", 0)), 1, "format")
	assert_eq(_golden.get("source_commit"), "0a0841f")
	assert_eq(_golden.get("dt"), hex_of(Config.DT), "the golden dt is the port's DT, bit for bit")
	var codes: Dictionary = _golden.get("codes", {})
	assert_eq(_snake_case(codes.get("kinds", [])), Config.KIND_NAMES, "traffic kind codes")
	assert_eq(_snake_case(codes.get("phases", [])), World.PHASE_NAMES, "phase codes")
	assert_eq(_snake_case(codes.get("events", [])), World.EVENT_NAMES, "event bits")
	var bits: Dictionary = _golden.get("input_bits", {})
	assert_eq(int(bits.get("accel", 0)), PlayerInput.ACCEL)
	assert_eq(int(bits.get("brake", 0)), PlayerInput.BRAKE)
	assert_eq(int(bits.get("steer_shift", 0)), PlayerInput.STEER_SHIFT)
	assert_eq(int(bits.get("high_gear", 0)), PlayerInput.NITRO)
	assert_eq(int(bits.get("pause", 0)), PlayerInput.PAUSE)
	assert_eq(int(bits.get("confirm", 0)), PlayerInput.CONFIRM)


## mulberry32: the first 64 outputs of 10 seeds, as the u32 behind next(), and next() itself.
func test_rng_matches_phaser_u32() -> void:
	var rng_section: Dictionary = _golden.get("rng", {})
	var seeds: Array = rng_section.get("first", [])
	assert_eq(seeds.size(), 10, "seeds in the golden file")
	for entry: Dictionary in seeds:
		var seed_value := int(entry["seed"])
		var expected := _ints(entry["u32"])
		var rng := Rng.new(seed_value)
		var got: Array[int] = []
		for i in expected.size():
			got.append(rng.next_u32())
		assert_eq(got, expected, "seed %d" % seed_value)
		var again := Rng.new(seed_value)
		assert_eq(again.next(), float(expected[0]) / 4294967296.0, "next() is the u32 / 2^32, seed %d" % seed_value)


## One million outputs of seed 20261014: xor, sum mod 2^32, FNV-1a and every 100 000th output.
func test_rng_million_outputs_match_phaser() -> void:
	var million: Dictionary = _golden.get("rng", {}).get("million", {})
	var count := int(million.get("count", 0))
	assert_eq(count, 1000000)
	var rng := Rng.new(int(million.get("seed", 0)))
	var xor := 0
	var sum := 0
	var fnv := FNV_OFFSET
	var samples: Array[int] = []
	for i in count:
		var u := rng.next_u32()
		xor ^= u
		sum = (sum + u) & U32_MASK
		fnv = ((fnv ^ u) * FNV_PRIME) & U32_MASK
		if i % 100000 == 99999:
			samples.append(u)
	assert_eq(xor, int(million.get("xor", -1)), "xor")
	assert_eq(sum, int(million.get("sum_mod_2_32", -1)), "sum mod 2^32")
	assert_eq(fnv, int(million.get("fnv", -1)), "FNV-1a")
	assert_eq(samples, _ints(million.get("every_100000th", [])), "every 100 000th output")


## int(), range() and pick() as the rules call them, seed 99, 200 rounds.
func test_rng_helpers_match_phaser() -> void:
	var helpers: Dictionary = _golden.get("rng", {}).get("helpers", {})
	var rounds := int(helpers.get("rounds", 0))
	assert_eq(rounds, 200)
	var rng := Rng.new(int(helpers.get("seed", 0)))
	var ints: Array[int] = []
	var ranges: Array[String] = []
	var picks: Array[int] = []
	for i in rounds:
		ints.append(rng.int_range(5, 6))
		ints.append(rng.int_range(2, 3))
		ranges.append(hex_of(rng.float_range(80.0, 120.0)))
		ranges.append(hex_of(rng.float_range(-1000.0, 1000.0)))
		ranges.append(hex_of(rng.float_range(1.0, 2.5)))
		picks.append([0, 1, 2][rng.pick_index(3)])
		picks.append([3, 7][rng.pick_index(2)])
	assert_eq(ints, _ints(helpers.get("ints", [])), "int()")
	assert_eq(ranges, _strings(helpers.get("ranges", [])), "range(), bit for bit")
	assert_eq(picks, _ints(helpers.get("picks", [])), "pick()")


## Car.step_speed() against 2000 calls of Phaser's stepSpeed() that reach every branch.
func test_golden_speed_trace_bit_exact() -> void:
	var trace: Dictionary = _golden.get("speed_trace", {})
	var inputs := _ints(trace.get("inputs", []))
	var expected := _strings(trace.get("speeds", []))
	assert_eq(int(trace.get("steps", 0)), 2000)
	assert_eq(inputs.size(), 2000)
	assert_eq(trace.get("dt"), hex_of(Config.DT))
	var speed := double_of(trace.get("start_speed", ""))
	var got: Array[String] = []
	for byte in inputs:
		var gear := Car.GEAR_NITRO if PlayerInput.nitro(byte) else Car.GEAR_LOW
		speed = Car.step_speed(speed, gear, PlayerInput.accel(byte), PlayerInput.brake(byte))
		got.append(hex_of(speed))
	assert_eq(_first_mismatch(got, expected), "", "speeds")


## Sixty seconds with no traffic in the six-lane game: speed and fuel bit-exact, distance (world y) equal to
## Phaser's distance x K within 1e-9 px, and the same pause.
func test_golden_no_traffic_60s() -> void:
	var result := _replay_no_traffic(Config.standard())
	assert_eq(result["speed"], "", "speed, bit for bit")
	assert_eq(result["fuel"], "", "fuel, bit for bit")
	assert_eq(result["phase"], "", "phase")
	assert_eq(result["traffic"], 0, "ticks with traffic on the road")
	assert_lt(result["distance_error"], DISTANCE_TOLERANCE, "world y against distance x K")
	assert_gt(result["last_distance"], 1000.0, "the run covered real distance")


## The same sixty seconds in the phaser profile (K = 1): the distance is bit-exact as well.
func test_golden_no_traffic_60s_phaser_profile_bit_exact() -> void:
	var result := _replay_no_traffic(Config.phaser())
	assert_eq(result["speed"], "", "speed, bit for bit")
	assert_eq(result["fuel"], "", "fuel, bit for bit")
	assert_eq(result["phase"], "", "phase")
	assert_eq(result["distance_exact"], "", "distance, bit for bit")
	assert_eq(result["traffic"], 0, "ticks with traffic on the road")


## world.gd with the phaser profile replays three minutes of Phaser games (seed 20261014, scripted inputs, one game
## over and restart): every column at every tick and a full snapshot every 60 ticks, exact except the traffic
## screen y (within 1e-6 px).
func test_golden_world_profile_phaser() -> void:
	var replay := _world_replay()
	assert_eq(replay["ticks"], 10800, "ticks replayed")
	for column: String in EXACT_COLUMNS:
		assert_eq(replay["columns"].get(column, ""), "", "column %s" % column)
	assert_eq(replay["snapshots"], 180, "snapshots compared")
	assert_eq(replay["snapshot_mismatch"], "", "snapshots")
	assert_lt(replay["screen_y_error"], SCREEN_Y_TOLERANCE, "traffic screen y (sum per tick and per object)")


## The world trace is only worth something if it reaches the rules: passes, bumps, oil, pickups, a roadside
## crash, stage clears, a game over and pause/resume, and lane changes of red and blue cars.
##
## The port records each event as one bit per step, Phaser as one entry per occurrence. Only a pickup can occur
## twice in one step (two fuel cars at once), so its count is not compared; the events column above is exact.
func test_golden_world_trace_covers_the_rules() -> void:
	var golden_counts: Dictionary = _golden.get("world_event_counts", {})
	var replay := _world_replay()
	var ours: Dictionary = replay["event_counts"]
	for event: String in ["pass", "bump", "skid", "pickup", "crash", "spin", "stage_clear", "game_over", "pause", "resume"]:
		assert_gt(int(ours.get(event, 0)), 0, "%s happens in the replay" % event)
		if event != "pickup":
			var golden_name := _camel_case(event)
			assert_eq(int(ours.get(event, 0)), int(golden_counts.get(golden_name, -1)), "%s count" % event)
	for kind: String in ["red", "blue"]:
		assert_gt(int(golden_counts.get("lane_change_" + kind, 0)), 0, "%s cars change lane in the trace" % kind)
	assert_eq(replay["restarts"], 1, "games restarted after a game over")


# --- Replays -------------------------------------------------------------------------------------------------------


func _replay_no_traffic(cfg: Config) -> Dictionary:
	var section: Dictionary = _golden.get("no_traffic_60s", {})
	var inputs := _ints(section.get("inputs", []))
	var speeds := _strings(section.get("speed", []))
	var fuels := _strings(section.get("fuel", []))
	var distances := _strings(section.get("distance", []))
	var phases := _ints(section.get("phase", []))
	var w := World.new(cfg, int(section.get("seed", 0)))
	w.spawner.car_gap = INF
	w.spawner.oil_gap = INF
	w.spawner.fuel_gap = INF
	var result := {
		"speed": "", "fuel": "", "phase": "", "distance_exact": "", "traffic": 0, "distance_error": 0.0,
		"last_distance": 0.0,
	}
	if inputs.size() != int(section.get("ticks", -1)) or inputs.is_empty():
		result["speed"] = "golden section no_traffic_60s is missing or malformed"
		return result
	for i in inputs.size():
		w.step(PackedByteArray([inputs[i]]))
		var p := w.player()
		_note(result, "speed", i, hex_of(p.speed), speeds[i])
		_note(result, "fuel", i, hex_of(p.fuel), fuels[i])
		_note(result, "phase", i, w.phase, phases[i])
		_note(result, "distance_exact", i, hex_of(p.y_world), distances[i])
		result["distance_error"] = maxf(result["distance_error"], absf(p.y_world - double_of(distances[i]) * cfg.k))
		if not w.traffic.is_empty():
			result["traffic"] += 1
		result["last_distance"] = p.y_world
	return result


## Replays world_phaser once and keeps the first mismatch of each column, the first snapshot mismatch, the largest
## screen y error and the events seen.
func _world_replay() -> Dictionary:
	if not _replay.is_empty():
		return _replay
	var section: Dictionary = _golden.get("world_phaser", {})
	var columns: Dictionary = section.get("columns", {})
	var expected := {}
	for column: String in EXACT_COLUMNS:
		var values: Array = columns.get(column, [])
		if column in ["x", "speed", "fuel", "distance"]:
			expected[column] = _strings(values)
		else:
			expected[column] = _ints(values)
	var inputs := _ints(columns.get("input", []))
	var y_sums := _strings(columns.get("traffic_y_sum", []))
	var snapshots: Array = section.get("snapshots", [])
	var restarts := {}
	for restart: Dictionary in section.get("restarts", []):
		restarts[int(restart["tick"])] = int(restart["seed"])

	var cfg := Config.phaser()
	var w := World.new(cfg, int(section.get("seed", 0)))
	var mismatches := {}
	var event_counts := {}
	var screen_y_error := 0.0
	var snapshot_index := 0
	var snapshot_mismatch := ""
	var restarted := 0
	var ticks := int(section.get("ticks", 0))
	if inputs.size() != ticks or y_sums.size() != ticks:
		ticks = 0
		snapshot_mismatch = "golden section world_phaser is missing or malformed"
	for tick in ticks:
		if restarts.has(tick):
			w = World.new(cfg, restarts[tick], 1, w.high_score)
			restarted += 1
		w.step(PackedByteArray([inputs[tick]]))
		var p := w.player()
		var got := {
			"phase": w.phase, "stage": w.stage, "x": hex_of(p.x), "speed": hex_of(p.speed), "fuel": hex_of(p.fuel),
			"distance": hex_of(p.y_world), "score": p.score, "events": w.events, "traffic_count": w.traffic.size(),
			"next_id": w.spawner.next_id, "traffic_hash": _traffic_hash(w), "player_hash": _player_hash(w),
		}
		for column: String in EXACT_COLUMNS:
			_note(mismatches, column, tick, got[column], expected[column][tick])
		var y_sum := 0.0
		for c: Traffic in w.traffic:
			y_sum += w.screen_y(c.y_world)
		screen_y_error = maxf(screen_y_error, absf(y_sum - double_of(y_sums[tick])))
		for bit in World.EVENT_NAMES.size():
			if (w.events & (1 << bit)) != 0:
				var name: String = World.EVENT_NAMES[bit]
				event_counts[name] = int(event_counts.get(name, 0)) + 1
		if tick % 60 == 59 and snapshot_index < snapshots.size():
			var golden_snapshot: Dictionary = snapshots[snapshot_index]
			snapshot_index += 1
			for i in w.traffic.size():
				var golden_traffic: Array = golden_snapshot.get("traffic", [])
				if i < golden_traffic.size():
					var golden_y := double_of(golden_traffic[i][3])
					screen_y_error = maxf(screen_y_error, absf(w.screen_y(w.traffic[i].y_world) - golden_y))
			if snapshot_mismatch.is_empty():
				var difference := _first_difference(_snapshot_of(w, tick), _normalise_snapshot(golden_snapshot), "")
				if not difference.is_empty():
					snapshot_mismatch = "tick %d: %s" % [tick, difference]
	_replay = {
		"ticks": ticks, "columns": mismatches, "snapshots": snapshot_index, "snapshot_mismatch": snapshot_mismatch,
		"screen_y_error": screen_y_error, "event_counts": event_counts, "restarts": restarted,
	}
	return _replay


# --- The generator's hashes and snapshot, rebuilt from the port's state ----------------------------------------------


static func _mix(h: int, word: int) -> int:
	return ((h ^ (word & U32_MASK)) * FNV_PRIME) & U32_MASK


static func _mix_double(h: int, value: float) -> int:
	var bytes := PackedByteArray()
	bytes.resize(8)
	bytes.encode_double(0, value)
	return _mix(_mix(h, bytes.decode_u32(0)), bytes.decode_u32(4))


## trafficHash() of the generator: everything about the traffic except the screen y.
static func _traffic_hash(w: World) -> int:
	var h := _mix(FNV_OFFSET, w.traffic.size())
	for c: Traffic in w.traffic:
		h = _mix(h, c.id)
		h = _mix(h, c.kind)
		h = _mix_double(h, c.x)
		h = _mix_double(h, c.kmh)
		h = _mix(h, 0 if c.target_lane < 0 else 1)
		if c.target_lane >= 0:
			h = _mix_double(h, Traffic.lane_x(w.cfg, c.target_lane, c.w))
		h = _mix(h, c.lanes_left)
		h = _mix(h, _flags(c))
		h = _mix(h, c.lane_timer)
	return h


## playerHash() of the generator.
static func _player_hash(w: World) -> int:
	var p := w.player()
	var h := _mix_double(FNV_OFFSET, p.slide_vx)
	h = _mix(h, p.invulnerable)
	h = _mix(h, p.gear)
	h = _mix(h, w.high_score)
	h = _mix(h, w.stage_ticks)
	h = _mix_double(h, w.goal)
	return h


## passed 1, struck 2, consumed 4: Phaser's booleans, from the per-seat masks of seat 0.
static func _flags(c: Traffic) -> int:
	return (1 if c.passed_mask != 0 else 0) | (2 if c.struck_mask != 0 else 0) | (4 if c.consumed_mask != 0 else 0)


## snapshot() of the generator, with the traffic screen y left out (compared separately, within a tolerance).
static func _snapshot_of(w: World, tick: int) -> Dictionary:
	var p := w.player()
	var traffic: Array = []
	for c: Traffic in w.traffic:
		var target := "" if c.target_lane < 0 else hex_of(Traffic.lane_x(w.cfg, c.target_lane, c.w))
		traffic.append([
			c.id, c.kind, hex_of(c.x), "screen y", c.w, c.h, hex_of(c.kmh), target, c.lanes_left, c.lane_timer,
			1 if c.passed_mask != 0 else 0, 1 if c.struck_mask != 0 else 0, 1 if c.consumed_mask != 0 else 0,
		])
	return {
		"tick": tick, "phase": w.phase, "stage": w.stage, "goal": hex_of(w.goal), "distance": hex_of(p.y_world),
		"score": p.score, "high_score": w.high_score, "stage_ticks": w.stage_ticks,
		"car": {
			"x": hex_of(p.x), "speed": hex_of(p.speed), "gear": p.gear, "slide_vx": hex_of(p.slide_vx),
			"invulnerable_ticks": p.invulnerable,
		},
		"fuel": hex_of(p.fuel),
		"spawner": {
			"car_gap": hex_of(w.spawner.car_gap), "oil_gap": hex_of(w.spawner.oil_gap),
			"fuel_gap": hex_of(w.spawner.fuel_gap), "next_id": w.spawner.next_id,
		},
		"traffic": traffic,
	}


## A golden snapshot with JSON numbers turned back into the port's ints and floats.
static func _normalise_snapshot(s: Dictionary) -> Dictionary:
	var car: Dictionary = s.get("car", {})
	var spawner: Dictionary = s.get("spawner", {})
	var traffic: Array = []
	for row: Array in s.get("traffic", []):
		traffic.append([
			int(row[0]), int(row[1]), row[2], "screen y", float(row[4]), float(row[5]), row[6], row[7], int(row[8]),
			int(row[9]), int(row[10]), int(row[11]), int(row[12]),
		])
	return {
		"tick": int(s.get("tick", -1)), "phase": int(s.get("phase", -1)), "stage": int(s.get("stage", -1)),
		"goal": s.get("goal"), "distance": s.get("distance"), "score": int(s.get("score", -1)),
		"high_score": int(s.get("high_score", -1)), "stage_ticks": int(s.get("stage_ticks", -1)),
		"car": {
			"x": car.get("x"), "speed": car.get("speed"), "gear": int(car.get("gear", -1)),
			"slide_vx": car.get("slide_vx"), "invulnerable_ticks": int(car.get("invulnerable_ticks", -1)),
		},
		"fuel": s.get("fuel"),
		"spawner": {
			"car_gap": spawner.get("car_gap"), "oil_gap": spawner.get("oil_gap"), "fuel_gap": spawner.get("fuel_gap"),
			"next_id": int(spawner.get("next_id", -1)),
		},
		"traffic": traffic,
	}


# --- Helpers -------------------------------------------------------------------------------------------------------


## Keeps the first mismatch of a column: "tick N: expected X, got Y".
static func _note(mismatches: Dictionary, column: String, tick: int, got: Variant, expected: Variant) -> void:
	if not strict_equal(got, expected) and str(mismatches.get(column, "")).is_empty():
		mismatches[column] = "tick %d: expected %s, got %s" % [tick, show(expected), show(got)]


## "" if the lists are equal, else the first index that differs.
static func _first_mismatch(got: Array, expected: Array) -> String:
	if got.size() != expected.size():
		return "%d values, expected %d" % [got.size(), expected.size()]
	for i in got.size():
		if not strict_equal(got[i], expected[i]):
			return "index %d: expected %s, got %s" % [i, show(expected[i]), show(got[i])]
	return ""


## Path and values of the first difference between two values, or "" when they are strictly equal.
static func _first_difference(got: Variant, expected: Variant, path: String) -> String:
	if typeof(got) != typeof(expected):
		return "%s: expected %s, got %s" % [path, show(expected), show(got)]
	if got is Dictionary:
		for key: Variant in expected:
			if not (got as Dictionary).has(key):
				return "%s.%s: missing" % [path, key]
		for key: Variant in got:
			if not (expected as Dictionary).has(key):
				return "%s.%s: not expected" % [path, key]
			var difference := _first_difference(got[key], expected[key], "%s.%s" % [path, key])
			if not difference.is_empty():
				return difference
		return ""
	if got is Array:
		if (got as Array).size() != (expected as Array).size():
			return "%s: %d items, expected %d" % [path, (got as Array).size(), (expected as Array).size()]
		for i in (got as Array).size():
			var difference := _first_difference(got[i], expected[i], "%s[%d]" % [path, i])
			if not difference.is_empty():
				return difference
		return ""
	return "" if got == expected else "%s: expected %s, got %s" % [path, show(expected), show(got)]


static func _ints(values: Array) -> Array[int]:
	var out: Array[int] = []
	for value: Variant in values:
		out.append(int(value))
	return out


static func _strings(values: Array) -> Array[String]:
	var out: Array[String] = []
	for value: Variant in values:
		out.append(str(value))
	return out


## "fuelCar" -> "fuel_car", as the port names its codes.
static func _snake_case(names: Array) -> Array:
	var out: Array = []
	for name: Variant in names:
		out.append(str(name).to_snake_case())
	return out


## "stage_clear" -> "stageClear", as the generator names its events.
static func _camel_case(name: String) -> String:
	return name.to_camel_case()
