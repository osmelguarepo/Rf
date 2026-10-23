extends RefCounted
## The developer dashboard's values (scripts/app/admin.gd): what a game's rules are changed to, and the presets that
## keep them. Dev only: App.admin_enabled is set by --admin. The values live in the app, so they carry over from game
## to game; each new game's Config gets them in apply(), and the dashboard applies them again to the running one.
##
## time_scale is not a rule of the simulation: it multiplies the real time the fixed step is given (App._process()),
## so the same rules run faster or slower. The other fields are Config's speed rules (low_gear_top ... nitro_recharge_px).
## A game with the default values is the game as shipped: apply() then changes nothing.

const Config := preload("res://scripts/sim/config.gd")

const TIME_SCALE := "time_scale"
const PRESET_SLOTS := 5
const PRESET_FILE := "user://admin_presets.json"

## The fields, in the order the dashboard shows them: {key, label, min, max, step}.
const FIELDS := [
	{"key": TIME_SCALE, "label": "Game speed x", "min": 0.1, "max": 4.0, "step": 0.05},
	{"key": "low_gear_top", "label": "Low gear top km/h", "min": 20.0, "max": 600.0, "step": 1.0},
	{"key": "nitro_top", "label": "Nitro top km/h", "min": 20.0, "max": 800.0, "step": 1.0},
	{"key": "low_gear_accel", "label": "Low accel km/h/s", "min": 1.0, "max": 400.0, "step": 1.0},
	{"key": "nitro_accel", "label": "Nitro accel km/h/s", "min": 1.0, "max": 400.0, "step": 1.0},
	{"key": "nitro_slow_accel", "label": "Nitro slow accel", "min": 1.0, "max": 400.0, "step": 1.0},
	{"key": "nitro_slow_below", "label": "Nitro slow below km/h", "min": 0.0, "max": 400.0, "step": 1.0},
	{"key": "brake_decel", "label": "Brake km/h/s", "min": 1.0, "max": 600.0, "step": 1.0},
	{"key": "drag_decel", "label": "Coast drag km/h/s", "min": 0.0, "max": 200.0, "step": 1.0},
	{"key": "overspeed_fall", "label": "Overspeed fall", "min": 1.0, "max": 400.0, "step": 1.0},
	{"key": "nitro_tank_seconds", "label": "Nitro tank s (0 = no tank)", "min": 0.0, "max": 30.0, "step": 0.5},
	{"key": "nitro_recharge_px", "label": "Refill every px", "min": 200.0, "max": 20000.0, "step": 100.0},
	{"key": "race_finish_px", "label": "Race length px (0 = old rules)", "min": 0.0, "max": 40000.0, "step": 250.0},
	{"key": "fuel_car_nitro", "label": "Fuel car refills nitro", "min": 0.0, "max": 1.0, "step": 0.05},
	{"key": "match_races", "label": "Races per match", "min": 1.0, "max": 9.0, "step": 1.0},
	{"key": "race_finish_grace_ticks", "label": "Finish countdown ticks (60 = 1 s)", "min": 0.0, "max": 3600.0, "step": 60.0},
	{"key": "race_start_ticks", "label": "Start countdown ticks (60 = 1 s)", "min": 0.0, "max": 600.0, "step": 30.0},
]

## Changed values only, key -> float.
var values: Dictionary = {}


## The shipped value of a field: the standard profile's, the game's own rules.
static func default_of(key: String) -> float:
	if key == TIME_SCALE:
		return 1.0
	return float(Config.game().get(key))


static func field_of(key: String) -> Dictionary:
	for field: Dictionary in FIELDS:
		if field["key"] == key:
			return field
	return {}


func value(key: String) -> float:
	return float(values.get(key, default_of(key)))


## Sets a field, kept within its range. An unknown key does nothing. A value equal to the shipped one is forgotten.
func set_value(key: String, v: float) -> void:
	var field := field_of(key)
	if field.is_empty() or is_nan(v):
		return
	var clamped := clampf(v, float(field["min"]), float(field["max"]))
	if is_equal_approx(clamped, default_of(key)):
		values.erase(key)
	else:
		values[key] = clamped


func reset() -> void:
	values.clear()


func is_default() -> bool:
	return values.is_empty()


## Gives a game's Config the speed rules (time_scale is the app's, not Config's).
func apply(cfg: Config) -> void:
	for field: Dictionary in FIELDS:
		var key: String = field["key"]
		if key != TIME_SCALE:
			cfg.set(key, roundi(value(key)) if typeof(cfg.get(key)) == TYPE_INT else value(key))


# --- Presets ---------------------------------------------------------------------------------------------------------


func _read_file() -> Dictionary:
	if not FileAccess.file_exists(PRESET_FILE):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PRESET_FILE))
	return parsed if parsed is Dictionary else {}


func has_preset(slot: int) -> bool:
	return _read_file().get(str(slot)) is Dictionary


## Keeps the present values in a slot (1 to PRESET_SLOTS). Returns false if the file cannot be written.
func save_preset(slot: int) -> bool:
	if slot < 1 or slot > PRESET_SLOTS:
		return false
	var file := _read_file()
	file[str(slot)] = values.duplicate()
	var out := FileAccess.open(PRESET_FILE, FileAccess.WRITE)
	if out == null:
		return false
	out.store_string(JSON.stringify(file, "\t"))
	return true


## Takes the values of a slot, whatever was set before. Returns false if the slot is empty.
func load_preset(slot: int) -> bool:
	var saved: Variant = _read_file().get(str(slot))
	if not (saved is Dictionary):
		return false
	values.clear()
	for key: Variant in saved:
		if key is String and (saved[key] is float or saved[key] is int):
			set_value(key, float(saved[key]))
	return true
