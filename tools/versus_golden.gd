extends SceneTree
## Rewrites tests/golden/versus_checksum.txt: the checksum of the versus golden scenario of
## tests/test_versus_golden.gd (6 seats driven by bot.gd for 7200 ticks, through Match), whose run_scenario() it calls,
## so the scenario is written down once. Only after a deliberate change to the rules, the bots, the traffic or the
## state's layout:
##
##   godot --headless --path . -s res://tools/versus_golden.gd
##
## It plays the scenario twice and writes the file only when both runs agree. It prints the old and the new checksum.
## Exit code 0 when written, 1 otherwise.

const Golden := preload("res://tests/test_versus_golden.gd")


func _initialize() -> void:
	var first := Golden.run_scenario()
	var second := Golden.run_scenario()
	if first != second:
		printerr("versus_golden: two runs differ (%s, %s); nothing written" % [first["checksum"], second["checksum"]])
		quit(1)
		return
	var path := ProjectSettings.globalize_path(Golden.GOLDEN_PATH)
	var old := FileAccess.get_file_as_string(Golden.GOLDEN_PATH).strip_edges()
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		printerr("versus_golden: cannot write %s" % path)
		quit(1)
		return
	file.store_string(str(first["checksum"]) + "\n")
	file.close()
	print("versus_golden: old %s" % (old if not old.is_empty() else "(none)"))
	print("versus_golden: new %s (rounds %d, winners %s, bots out %d, fuel cars %d)" % [
		first["checksum"], first["rounds"], first["winners"], first["bots_out"], first["pickups"]
	])
	print("versus_golden: wrote %s" % path)
	quit(0)
