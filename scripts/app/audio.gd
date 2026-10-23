extends Node
## The game's sound (docs/AUDIO.md): retro effects that the screens trigger from what the simulation did. The simulation
## itself never makes a sound, so a silent run (headless, the tests) plays the same game.
##
## Races (Versus calls race_step() after each step of the match and drive() once a frame):
## - the start gantry: a beep for each red light and a higher one at the green;
## - for the people's cars (bots are silent, or six cars would be a din): a crash, a bump, a skid, a fuel-car pickup, the
##   nitro tank filling up, nitro burning (a whoosh and a loop), crossing the line, and an overtake;
## - the engine, a loop for the fastest person's car whose pitch follows its speed (idle while the lights count down);
## - a jingle when a race ends, a win or lose jingle at the match's end and a rising or falling one when the division
##   changed, a tick on pause and resume.
## Menus: a tick on a move, a blip on confirm and on back (menu()).
##
## `played` keeps the names of the last sounds asked for, which is what the tests look at.

const World := preload("res://scripts/sim/world.gd")
const Car := preload("res://scripts/sim/car.gd")
const Match := preload("res://scripts/sim/match.gd")
const Nav := preload("res://scripts/input/nav.gd")
const Ranking := preload("res://scripts/sim/ranking.gd")
const VersusHud := preload("res://scripts/view/versus_hud.gd")

## The sounds by name: the ones tools/gen_audio.gd makes, and Kenney's (assets/audio/kenney/, CC0).
const STREAMS := {
	"beep_light": preload("res://assets/audio/beep_light.wav"),
	"beep_go": preload("res://assets/audio/beep_go.wav"),
	"engine": preload("res://assets/audio/engine.wav"),
	"nitro_start": preload("res://assets/audio/nitro_start.wav"),
	"nitro_loop": preload("res://assets/audio/nitro_loop.wav"),
	"crash": preload("res://assets/audio/crash.wav"),
	"bump": preload("res://assets/audio/bump.wav"),
	"skid": preload("res://assets/audio/skid.wav"),
	"finish": preload("res://assets/audio/finish.wav"),
	"pause": preload("res://assets/audio/pause.wav"),
	"menu_move": preload("res://assets/audio/menu_move.wav"),
	"menu_confirm": preload("res://assets/audio/menu_confirm.wav"),
	"menu_back": preload("res://assets/audio/menu_back.wav"),
	"pickup": preload("res://assets/audio/kenney/powerUp2.ogg"),
	"nitro_ready": preload("res://assets/audio/kenney/powerUp5.ogg"),
	"overtake": preload("res://assets/audio/kenney/phaserUp5.ogg"),
	"round_end": preload("res://assets/audio/kenney/threeTone1.ogg"),
	"match_win": preload("res://assets/audio/kenney/threeTone2.ogg"),
	"match_lose": preload("res://assets/audio/kenney/lowThreeTone.ogg"),
	"rank_up": preload("res://assets/audio/kenney/zapThreeToneUp.ogg"),
	"rank_down": preload("res://assets/audio/kenney/zapThreeToneDown.ogg"),
}
## Names that loop: the engine and the nitro burn.
const LOOPS := ["engine", "nitro_loop"]
## Volume of each sound, in dB (the engine and nitro sit under the effects).
const VOLUME_DB := {"engine": -12.0, "nitro_loop": -14.0, "nitro_start": -8.0, "skid": -8.0, "menu_move": -10.0, "bump": -4.0}
const DEFAULT_DB := -6.0
## The engine's pitch scale: idle, and at the top speed.
const ENGINE_PITCH_IDLE := 0.6
const ENGINE_PITCH_TOP := 3.0
const TOP_SPEED := 400.0
## Seconds after a match ends before the division sound.
const RANK_DELAY := 1.0
const LOG_SIZE := 64

## The last sounds asked for, oldest first.
var played: Array[String] = []

var _players: Dictionary = {}
# Race memory, for what changed since the last step.
var _lights := 0
var _countdown := -1
var _world_phase := -1
var _match_phase := -1
var _places: Dictionary = {}
var _finished: Dictionary = {}
var _full: Dictionary = {}
var _burning := false
var _delayed: Array = []


func _init() -> void:
	for sound_name: String in STREAMS:
		var player := AudioStreamPlayer.new()
		player.stream = STREAMS[sound_name]
		player.volume_db = VOLUME_DB.get(sound_name, DEFAULT_DB)
		player.max_polyphony = 1 if LOOPS.has(sound_name) else 3
		add_child(player)
		_players[sound_name] = player
	for sound_name: String in LOOPS:
		var wav: AudioStreamWAV = STREAMS[sound_name]
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = wav.data.size() >> 1


## Plays a sound once from its start.
func play(sound_name: String) -> void:
	played.append(sound_name)
	if played.size() > LOG_SIZE:
		played.remove_at(0)
	var player: AudioStreamPlayer = _players.get(sound_name)
	if player != null and is_inside_tree():
		player.play()


## Plays a sound `seconds` from now (advance() counts them down).
func play_later(sound_name: String, seconds: float) -> void:
	_delayed.append([seconds, sound_name])


## A menu command (nav.gd): a tick on a move, a blip on confirm, another on back.
func menu(command: int) -> void:
	match command:
		Nav.UP, Nav.DOWN, Nav.LEFT, Nav.RIGHT:
			play("menu_move")
		Nav.ACCEPT, Nav.START:
			play("menu_confirm")
		Nav.BACK, Nav.SELECT:
			play("menu_back")


## A match starts: forget what the last one did.
func begin_race() -> void:
	stop_loops()
	_lights = 0
	_countdown = -1
	_world_phase = -1
	_match_phase = -1
	_places.clear()
	_finished.clear()
	_full.clear()
	_burning = false
	_delayed.clear()


func stop_loops() -> void:
	for sound_name: String in LOOPS:
		(_players[sound_name] as AudioStreamPlayer).stop()
	_burning = false


## Counts the delayed sounds down, `delta` seconds on.
func advance(delta: float) -> void:
	var left: Array = []
	for entry: Array in _delayed:
		entry[0] = float(entry[0]) - delta
		if float(entry[0]) <= 0.0:
			play(entry[1])
		else:
			left.append(entry)
	_delayed = left


## What the step that just ran did, as sound: call it after every step of the match.
func race_step(m: Match) -> void:
	var w := m.world
	_start_lights(w)
	if _match_phase == Match.PLAYING and m.phase == Match.ROUND_OVER:
		play("round_end")
	_match_phase = m.phase
	if _world_phase >= 0 and w.phase != _world_phase and w.phase != World.ROUND_OVER and _world_phase != World.ROUND_OVER:
		play("pause")
	_world_phase = w.phase
	var standings := w.standings()
	var crashed := false
	var bumped := false
	for p: Car in w.players:
		if p.human == 0:
			continue
		if (p.events & World.EV_CRASH) != 0:
			crashed = true
		elif (p.events & World.EV_BUMP) != 0:
			bumped = true
		if (p.events & World.EV_SKID) != 0:
			play("skid")
		if (p.events & World.EV_PICKUP) != 0:
			play("pickup")
		var full := p.nitro_tank >= 1.0
		if full and not bool(_full.get(p.slot, true)):
			play("nitro_ready")
		_full[p.slot] = full
		if p.finish_place > 0 and not bool(_finished.get(p.slot, false)):
			play("finish")
		_finished[p.slot] = p.finish_place > 0
		var place := standings.find(p.slot)
		if w.countdown == 0 and place < int(_places.get(p.slot, place)):
			play("overtake")
		_places[p.slot] = place
	if crashed:
		play("crash")
	elif bumped:
		play("bump")


## The gantry's sounds: a beep as each red light comes on, a higher one when they go out.
func _start_lights(w: World) -> void:
	var lit := VersusHud.start_lights_lit(w)
	if lit > _lights:
		play("beep_light")
	if _countdown > 0 and w.countdown == 0:
		play("beep_go")
	_lights = lit
	_countdown = w.countdown


## The loops, once a frame: the engine of the fastest person's car (idle while the lights count down), and the nitro
## burn while any person's car uses it. Both stop when the race does.
func drive(m: Match) -> void:
	var w := m.world
	var racing := m.phase == Match.PLAYING and w.phase == World.RUNNING
	var fastest := -1.0
	var burning := false
	for p: Car in w.players:
		if p.human != 0 and p.alive != 0:
			fastest = maxf(fastest, p.speed)
			burning = burning or (p.gear == Car.GEAR_NITRO and p.speed > 0.0)
	var engine: AudioStreamPlayer = _players["engine"]
	if racing and fastest >= 0.0:
		engine.pitch_scale = engine_pitch(fastest)
		if not engine.playing and is_inside_tree():
			engine.play()
	else:
		engine.stop()
	var nitro: AudioStreamPlayer = _players["nitro_loop"]
	if racing and burning:
		if not _burning:
			play("nitro_start")
		if not nitro.playing and is_inside_tree():
			nitro.play()
	else:
		nitro.stop()
	_burning = racing and burning


## The engine's pitch scale for a speed in km/h: from idle to the top, in a line.
static func engine_pitch(speed: float) -> float:
	return ENGINE_PITCH_IDLE + (ENGINE_PITCH_TOP - ENGINE_PITCH_IDLE) * clampf(speed / TOP_SPEED, 0.0, 1.0)


## The match is decided (results: slot -> {before, after, delta} for the people): the winner's jingle for a person, the sad
## one for a person in the last place, and the division sound if a person's division changed.
func match_result(m: Match, results: Dictionary) -> void:
	var order := m.ranking_order()
	var humans := m.human_seats()
	if humans.has(m.winner):
		play("match_win")
	elif not order.is_empty() and humans.has(order.back()):
		play("match_lose")
	var up := false
	var down := false
	for slot: int in results:
		var change := Ranking.division(results[slot]["after"]) - Ranking.division(results[slot]["before"])
		up = up or change > 0
		down = down or change < 0
	if up:
		play_later("rank_up", RANK_DELAY)
	elif down:
		play_later("rank_down", RANK_DELAY)
