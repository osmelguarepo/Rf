extends SceneTree
## Writes the ranking tables the API (backend/, Go) must match, from the game's own code (scripts/sim/ranking.gd and
## Config.RACE_POINTS), as JSON for backend/testdata/ranking_tables.json. The Go test internal/ranking compares that file
## with its tables and fails on any difference, so a change to ranking.gd shows up as a failing test until this tool is
## run again and the Go tables are updated.
##
##   godot --headless --path . -s res://tools/export_ranking_tables.gd [-- --out=PATH]
##
## PATH defaults to backend/testdata/ranking_tables.json in the project. Exit code 0, or 1 if the file cannot be written.

const Ranking := preload("res://scripts/sim/ranking.gd")
const Config := preload("res://scripts/sim/config.gd")

const DEFAULT_OUT := "res://backend/testdata/ranking_tables.json"
## Totals whose division and distance to the next division are recorded: every edge and a point either side.
const SAMPLE_POINTS: Array[int] = [0, 1, 299, 300, 301, 699, 700, 701, 1199, 1200, 1201, 1799, 1800, 1801, 2500, 10000]
## Changes applied to a total, to record the floor of 0.
const SAMPLE_CHANGES: Array[int] = [-30, -1, 0, 1, 30]


func _initialize() -> void:
	var out_path := DEFAULT_OUT
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out_path = arg.substr(6)
	var file := FileAccess.open(out_path, FileAccess.WRITE)
	if file == null:
		printerr("export_ranking_tables: cannot write ", out_path)
		quit(1)
		return
	file.store_string(JSON.stringify(_tables(), "\t", true) + "\n")
	file.close()
	print("export_ranking_tables: wrote ", out_path)
	quit(0)


func _tables() -> Dictionary:
	var tables := {}
	for field in range(2, 7):
		var row: Array = []
		for place in field:
			row.append(Ranking.delta(field, place))
		tables[str(field)] = row
	var divisions: Array = []
	for points in SAMPLE_POINTS:
		divisions.append({
			"points": points,
			"division": Ranking.division(points),
			"name": Ranking.division_name(points),
			"to_next": Ranking.points_to_next(points),
		})
	var applies: Array = []
	for points in SAMPLE_POINTS:
		for change in SAMPLE_CHANGES:
			applies.append({"points": points, "change": change, "result": Ranking.apply(points, change)})
	return {
		"tables": tables,
		"division_starts": Ranking.DIVISION_STARTS,
		"division_names": Ranking.DIVISION_NAMES,
		"race_points": Config.RACE_POINTS,
		"divisions": divisions,
		"applies": applies,
	}
