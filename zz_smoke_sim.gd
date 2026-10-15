extends SceneTree
const Config := preload("res://scripts/sim/config.gd")
const World := preload("res://scripts/sim/world.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")
func _initialize() -> void:
	for cfg: Config in [Config.standard(), Config.phaser()]:
		var w := World.new(cfg, 12345)
		var t0 := Time.get_ticks_msec()
		var ev := {}
		for i in 10800:
			var steer := (floori(i / 90.0) % 3) - 1
			var b := PackedByteArray([PlayerInput.encode(true, false, steer, w.player().speed >= 190.0)])
			if w.phase == World.STAGE_CLEAR and i % 30 == 0:
				b[0] = PlayerInput.encode(false, false, 0, false, false, true)
			w.step(b)
			for e in World.EVENT_NAMES.size():
				if w.events & (1 << e):
					ev[World.EVENT_NAMES[e]] = ev.get(World.EVENT_NAMES[e], 0) + 1
		print("profile ", cfg.profile, " phase ", w.phase, " stage ", w.stage, " score ", w.player().score, " traffic ", w.traffic.size(), " ms ", Time.get_ticks_msec() - t0, " ", ev)
		print(" checksum ", w.checksum(), " clone ", w.clone().checksum() == w.checksum(), " restore ", World.from_array(cfg, w.to_array()).checksum() == w.checksum())
	quit(0)
