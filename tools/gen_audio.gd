extends SceneTree
## Makes the game's own sound effects, the ones assets/audio/kenney/ does not have: retro square, noise and sweep
## synthesis, 22 050 Hz mono 16-bit WAV, written to assets/audio/. Deterministic (a seeded noise source), so a run gives
## the same files. Own work, released as CC0-1.0 (assets/audio/README.md).
##
##   godot --headless --path . -s res://tools/gen_audio.gd

const RATE := 22050
const OUT := "res://assets/audio/"
var _noise_state := 12345


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	_save("beep_light", _beep(440.0, 0.16, 0.25))
	_save("beep_go", _beep(880.0, 0.7, 0.4))
	_save("engine", _engine())
	_save("nitro_start", _whoosh(0.4, 400.0, 3000.0))
	_save("nitro_loop", _noise_loop(0.5))
	_save("crash", _crash())
	_save("bump", _thud(0.18))
	_save("skid", _skid(0.7))
	_save("finish", _fanfare())
	_save("pause", _beep(1200.0, 0.05, 0.12))
	_save("menu_move", _beep(660.0, 0.045, 0.1))
	_save("menu_confirm", _two_tone(660.0, 990.0, 0.06))
	_save("menu_back", _two_tone(660.0, 440.0, 0.06))
	quit()


func _noise() -> float:
	# xorshift32: stable across platforms.
	_noise_state ^= (_noise_state << 13) & 0xFFFFFFFF
	_noise_state ^= _noise_state >> 17
	_noise_state ^= (_noise_state << 5) & 0xFFFFFFFF
	return float(_noise_state & 0xFFFF) / 32768.0 - 1.0


static func _square(phase: float, duty: float = 0.5) -> float:
	return 1.0 if fposmod(phase, 1.0) < duty else -1.0


## A square tone with a fast attack and a decay to nothing.
func _beep(freq: float, seconds: float, volume: float) -> PackedFloat32Array:
	var n := int(seconds * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var t := float(i) / RATE
		var env := minf(1.0, t / 0.004) * (1.0 - float(i) / n)
		out[i] = _square(t * freq) * env * volume
	return out


func _two_tone(a: float, b: float, each: float) -> PackedFloat32Array:
	var out := _beep(a, each, 0.1)
	out.append_array(_beep(b, each, 0.1))
	return out


## A loop of exactly one second: square waves at 60 and 120 Hz (whole cycles, so the loop is seamless) and a little
## noise. The game raises its pitch with the car's speed.
func _engine() -> PackedFloat32Array:
	var n := RATE
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var t := float(i) / RATE
		var body := _square(t * 60.0, 0.35) * 0.5 + _square(t * 120.0, 0.25) * 0.3 + _square(t * 180.0, 0.5) * 0.1
		out[i] = body * 0.35 + _noise() * 0.04
	return out


## Noise whose brightness rises: a one-pole low-pass moving its cut-off from `low` to `high` Hz.
func _whoosh(seconds: float, low: float, high: float) -> PackedFloat32Array:
	var n := int(seconds * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var y := 0.0
	for i in n:
		var progress := float(i) / n
		var cutoff := low + (high - low) * progress
		var a := clampf(cutoff / RATE * TAU, 0.0, 1.0)
		y += a * (_noise() - y)
		out[i] = y * 1.6 * minf(1.0, progress * 8.0) * (1.0 - progress * 0.5) * 0.5
	return out


## A half-second loop of band-limited noise, its ends cross-faded so it does not click.
func _noise_loop(seconds: float) -> PackedFloat32Array:
	var n := int(seconds * RATE)
	var raw := PackedFloat32Array()
	raw.resize(n)
	var y := 0.0
	for i in n:
		y += 0.35 * (_noise() - y)
		raw[i] = y
	var fade := 1200
	for i in fade:
		var k := float(i) / fade
		raw[i] = raw[i] * k + raw[n - fade + i] * (1.0 - k)
	var out := PackedFloat32Array()
	out.append_array(raw.slice(0, n - fade))
	for i in out.size():
		out[i] *= 0.4
	return out


## Noise with a falling square rumble: the crunch of a crash.
func _crash() -> PackedFloat32Array:
	var n := int(0.55 * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var phase := 0.0
	var y := 0.0
	for i in n:
		var p := float(i) / n
		phase += (140.0 - 100.0 * p) / RATE
		y += 0.6 * (_noise() - y)
		out[i] = (y * 0.7 + _square(phase) * 0.35) * pow(1.0 - p, 1.5) * 0.7
	return out


## A low thump: a sine falling from 120 to 50 Hz and a click.
func _thud(seconds: float) -> PackedFloat32Array:
	var n := int(seconds * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var phase := 0.0
	for i in n:
		var p := float(i) / n
		phase += (120.0 - 70.0 * p) / RATE
		out[i] = (sin(phase * TAU) * 0.8 + (_noise() * 0.3 if i < 120 else 0.0)) * (1.0 - p) * 0.7
	return out


## A tyre screech: a shrill square wobbling between 1500 and 1900 Hz over hissing noise.
func _skid(seconds: float) -> PackedFloat32Array:
	var n := int(seconds * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var phase := 0.0
	for i in n:
		var t := float(i) / RATE
		var p := float(i) / n
		phase += (1700.0 + 200.0 * sin(t * TAU * 9.0)) / RATE
		var env := minf(1.0, p * 10.0) * minf(1.0, (1.0 - p) * 6.0)
		out[i] = (_square(phase, 0.3) * 0.22 + _noise() * 0.18) * env
	return out


## C, E, G, then a long high C: the chequered flag.
func _fanfare() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for freq: float in [523.25, 659.25, 783.99]:
		out.append_array(_beep(freq, 0.13, 0.3))
	out.append_array(_beep(1046.5, 0.55, 0.32))
	return out


func _save(file: String, samples: PackedFloat32Array) -> void:
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		bytes.encode_s16(i * 2, clampi(roundi(samples[i] * 32767.0), -32768, 32767))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.stereo = false
	wav.data = bytes
	var path := OUT + file + ".wav"
	wav.save_to_wav(path)
	print("gen_audio: %s %.2f s" % [path, float(samples.size()) / RATE])
