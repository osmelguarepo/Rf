extends "res://tests/test_case.gd"
## The sound (scripts/app/audio.gd; docs/AUDIO.md): every sound loads, each game event asks for its sound, the engine pitch
## follows speed, and the loops are seamless. Nothing here listens: it reads `played`, the log of sounds asked for.

const Audio := preload("res://scripts/app/audio.gd")
const H := preload("res://tests/sim_helpers.gd")
const Config := preload("res://scripts/sim/config.gd")
const World := preload("res://scripts/sim/world.gd")
const Match := preload("res://scripts/sim/match.gd")
const Car := preload("res://scripts/sim/car.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")
const Nav := preload("res://scripts/input/nav.gd")

var audio: Audio


func before_each() -> void:
	audio = Audio.new()


func after_each() -> void:
	audio.free()
	audio = null


func _match(countdown: bool = false) -> Match:
	var m := Match.create(Config.game(), 7, 3, 0b001)
	if not countdown:
		H.quiet(m.world)
	audio.begin_race()
	return m


func _step(m: Match, bytes: Array = [PlayerInput.NONE, PlayerInput.BOT, PlayerInput.BOT]) -> void:
	m.step(PackedByteArray(bytes))
	audio.race_step(m)


func test_every_sound_loads_and_has_a_length() -> void:
	for sound_name: String in Audio.STREAMS:
		var stream: AudioStream = Audio.STREAMS[sound_name]
		assert_not_null(stream, sound_name)
		assert_gt(stream.get_length(), 0.0, sound_name)
		assert_lt(stream.get_length(), 2.0, "%s is a short effect" % sound_name)


func test_the_loops_loop_over_their_whole_length() -> void:
	for sound_name: String in Audio.LOOPS:
		var wav: AudioStreamWAV = Audio.STREAMS[sound_name]
		assert_eq(wav.loop_mode, AudioStreamWAV.LOOP_FORWARD, sound_name)
		assert_eq(wav.loop_end, wav.data.size() >> 1, sound_name)


func test_the_gantry_beeps_five_times_then_goes() -> void:
	var m := _match(true)
	for tick in 3 * Config.TICKS_PER_SECOND + 5:
		_step(m)
	var beeps := audio.played.count("beep_light")
	assert_eq(beeps, 5, "one beep for each red light")
	assert_eq(audio.played.count("beep_go"), 1)
	assert_lt(audio.played.rfind("beep_light"), audio.played.find("beep_go"), "the green comes after the reds")


func test_a_persons_crash_bump_skid_and_pickup_make_their_sounds_and_a_bots_do_not() -> void:
	var m := _match()
	m.world.players[1].events = World.EV_CRASH
	audio.race_step(m)
	assert_eq(audio.played, [] as Array[String], "a bot's crash is silent")
	m.world.players[0].events = World.EV_CRASH | World.EV_SKID
	audio.race_step(m)
	assert_eq(audio.played, ["skid", "crash"] as Array[String])
	audio.played.clear()
	m.world.players[0].events = World.EV_BUMP | World.EV_PICKUP
	audio.race_step(m)
	assert_eq(audio.played, ["pickup", "bump"] as Array[String])


func test_the_nitro_tank_filling_up_pings_once() -> void:
	var m := _match()
	audio.race_step(m)
	m.world.players[0].nitro_tank = 0.2
	audio.race_step(m)
	assert_false(audio.played.has("nitro_ready"))
	m.world.players[0].nitro_tank = 1.0
	audio.race_step(m)
	audio.race_step(m)
	assert_eq(audio.played.count("nitro_ready"), 1)


func test_crossing_the_line_and_overtaking() -> void:
	var m := _match()
	m.world.players[0].y_world = 100.0
	m.world.players[1].y_world = 300.0
	m.world.players[2].y_world = 200.0
	audio.race_step(m)
	m.world.players[0].y_world = 250.0
	audio.race_step(m)
	assert_eq(audio.played, ["overtake"] as Array[String], "a person passed a car")
	audio.played.clear()
	m.world.players[0].y_world = 900.0
	audio.race_step(m)
	assert_eq(audio.played, ["overtake"] as Array[String], "and another")
	audio.played.clear()
	m.world.players[0].finish_place = 1
	m.world.players[0].alive = 0
	audio.race_step(m)
	audio.race_step(m)
	assert_eq(audio.played, ["finish", "cheer"] as Array[String], "once, with the crowd")


func test_a_race_ending_a_pause_and_a_resume() -> void:
	var m := _match()
	_step(m)
	_step(m, [PlayerInput.PAUSE, PlayerInput.BOT, PlayerInput.BOT])
	_step(m, [PlayerInput.PAUSE, PlayerInput.BOT, PlayerInput.BOT])
	assert_eq(audio.played, ["pause", "pause"] as Array[String], "pausing and resuming tick")
	audio.played.clear()
	H.arrive(m.world, 1)
	_step(m)
	assert_true(audio.played.has("round_end"), "the race ended")
	assert_eq(audio.played[0], "round_end", "before the cars' own sounds")


func test_the_engine_pitch_rises_with_speed_within_its_range() -> void:
	assert_eq(Audio.engine_pitch(0.0), Audio.ENGINE_PITCH_IDLE)
	assert_eq(Audio.engine_pitch(400.0), Audio.ENGINE_PITCH_TOP)
	assert_eq(Audio.engine_pitch(900.0), Audio.ENGINE_PITCH_TOP, "never above the top")
	assert_eq(Audio.engine_pitch(-5.0), Audio.ENGINE_PITCH_IDLE, "never below idle")
	assert_gt(Audio.engine_pitch(250.0), Audio.engine_pitch(100.0))


func test_drive_runs_the_engine_and_nitro_only_while_the_race_runs() -> void:
	var m := _match()
	audio.drive(m)
	var engine: AudioStreamPlayer = audio._players["engine"]

	m.world.players[0].speed = 200.0
	audio.drive(m)
	assert_almost_eq(engine.pitch_scale, Audio.engine_pitch(200.0), 1e-6)
	m.world.players[0].gear = Car.GEAR_NITRO
	audio.drive(m)
	audio.drive(m)
	assert_eq(audio.played.count("nitro_start"), 1, "the whoosh once")
	m.world.phase = World.PAUSED
	audio.drive(m)
	assert_false(engine.playing, "silent while paused")
	assert_false(audio._burning, "and no nitro")
	assert_false((audio._players["nitro_loop"] as AudioStreamPlayer).playing)


func test_menu_commands_tick_and_blip() -> void:
	audio.menu(Nav.DOWN)
	audio.menu(Nav.ACCEPT)
	audio.menu(Nav.BACK)
	assert_eq(audio.played, ["menu_move", "menu_confirm", "menu_back"] as Array[String])


func test_a_match_result_plays_the_win_or_lose_jingle_and_the_division_sound_later() -> void:
	var m := _match()
	m.winner = 0
	audio.match_result(m, {0: {"before": 290, "after": 320, "delta": 30}})
	assert_eq(audio.played, ["match_win"] as Array[String])
	audio.advance(0.5)
	assert_eq(audio.played.size(), 1, "the division sound waits")
	audio.advance(0.6)
	assert_eq(audio.played, ["match_win", "rank_up"] as Array[String])
	audio.played.clear()
	m.winner = 1
	m.race_points = [1, 20, 10] as Array[int]
	audio.match_result(m, {0: {"before": 310, "after": 280, "delta": -30}})
	assert_eq(audio.played, ["match_lose"] as Array[String], "the person ended last")
	audio.advance(1.1)
	assert_eq(audio.played, ["match_lose", "rank_down"] as Array[String])


func test_a_person_passing_traffic_whooshes_and_a_bot_does_not() -> void:
	var m := _match()
	m.world.players[1].events = World.EV_PASS
	audio.race_step(m)
	assert_eq(audio.played, [] as Array[String])
	m.world.players[0].events = World.EV_PASS
	audio.race_step(m)
	assert_eq(audio.played, ["car_pass"] as Array[String])


func test_a_low_nitro_tank_beeps_at_once_and_then_every_half_second() -> void:
	var m := _match()
	var p := m.world.players[0]
	p.gear = Car.GEAR_NITRO
	p.speed = 200.0
	p.nitro_tank = 0.5
	audio.race_step(m)
	assert_false(audio.played.has("nitro_low"), "a tank above the line is quiet")
	p.nitro_tank = Audio.LOW_NITRO_TANK - 0.01
	audio.race_step(m)
	assert_eq(audio.played.count("nitro_low"), 1, "the first beep is at once")
	for i in Audio.LOW_NITRO_TICKS - 1:
		audio.race_step(m)
	assert_eq(audio.played.count("nitro_low"), 1)
	audio.race_step(m)
	assert_eq(audio.played.count("nitro_low"), 2, "and the next one a half second on")
	p.gear = Car.GEAR_LOW
	audio.race_step(m)
	assert_eq(audio.played.count("nitro_low"), 2, "none when nitro is not burning")


func test_the_race_song_plays_once_the_lights_go_out_and_stops_when_the_race_ends() -> void:
	var m := _match(true)
	audio.race_step(m)
	assert_eq(audio.music_playing, "", "silent while the lights count down")
	for tick in 3 * Config.TICKS_PER_SECOND + 1:
		_step(m)
	assert_eq(audio.music_playing, "music_race")
	H.arrive(m.world, 1)
	_step(m)
	assert_eq(audio.music_playing, "", "the jingle has the room")


func test_the_music_switches_and_the_same_song_goes_on() -> void:
	audio.music("music_menu")
	assert_eq(audio.music_playing, "music_menu")
	audio.music("music_menu")
	audio.music("music_race")
	assert_eq(audio.music_playing, "music_race")
	audio.music("")
	assert_eq(audio.music_playing, "")
	assert_eq(audio.played, [] as Array[String], "songs are not in the log of effects")


func test_the_songs_loop_over_their_whole_length() -> void:
	for song: String in Audio.MUSIC:
		var wav: AudioStreamWAV = Audio.MUSIC[song]
		assert_eq(wav.loop_mode, AudioStreamWAV.LOOP_FORWARD, song)
		assert_eq(wav.loop_end, wav.data.size() >> 1, song)
		assert_gt(wav.get_length(), 8.0, song)


func test_the_volume_goes_in_tenths_between_silence_and_full_and_mute_toggles() -> void:
	var bus_db := AudioServer.get_bus_volume_db(0)
	var bus_mute := AudioServer.is_bus_mute(0)
	for i in 20:
		audio.volume_up()
	assert_eq(audio.volume, Audio.VOLUME_STEPS)
	assert_almost_eq(AudioServer.get_bus_volume_db(0), 0.0, 1e-4)
	assert_eq(audio.volume_text(), "VOL 10/10")
	audio.volume_down()
	assert_eq(audio.volume, Audio.VOLUME_STEPS - 1)
	audio.toggle_mute()
	assert_true(AudioServer.is_bus_mute(0))
	assert_eq(audio.volume_text(), "MUTE")
	audio.volume_up()
	assert_false(audio.muted, "raising it unmutes")
	for i in 20:
		audio.volume_down()
	assert_eq(audio.volume, 0)
	assert_true(AudioServer.is_bus_mute(0), "zero is silent")
	AudioServer.set_bus_volume_db(0, bus_db)
	AudioServer.set_bus_mute(0, bus_mute)


func test_the_volume_is_saved_and_read_back() -> void:
	var path := "user://test_settings.cfg"
	var bus_db := AudioServer.get_bus_volume_db(0)
	var bus_mute := AudioServer.is_bus_mute(0)
	audio.settings_path = path
	audio.volume_down()
	audio.volume_down()
	audio.toggle_mute()
	var other := Audio.new()
	other.settings_path = path
	other.load_settings()
	assert_eq(other.volume, Audio.DEFAULT_VOLUME - 2)
	assert_true(other.muted)
	other.free()
	DirAccess.remove_absolute(path)
	AudioServer.set_bus_volume_db(0, bus_db)
	AudioServer.set_bus_mute(0, bus_mute)
