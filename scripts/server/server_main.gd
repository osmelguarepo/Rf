extends SceneTree
## The game server's entry point (docs/SPEC_ONLINE.md §3, §11, §16.1 10). Headless, one process, many rooms:
##
##   godot --headless --path . -s res://scripts/server/server_main.gd -- --port=9080 --region=eu --key=SECRET [--dev]
##
## --port      TCP port the WebSocket listener binds (default 9080). A proxy (Caddy) terminates TLS in front of it.
## --region    a label for the logs (the matchmaker will use it).
## --key       the shared secret that signs match tickets (or the FUEL_SERVER_KEY environment variable). Each server has its own.
## --dev       accept unsigned "dev." tickets and run without a key. Never in production.
## --no-private  refuse private rooms.
## --race-px=N, --races=N  shorter races for a try-out (the match's rules, sent to every client in WELCOME).
## --max-seconds=N  stop after N seconds (tools and tests).
## Every match that ends prints one "result: {...}" line (JSON, SteamIDs as text) and saves its replay to user://replays/.

const Host := preload("res://scripts/server/host.gd")
const WsServer := preload("res://scripts/net/ws_server.gd")
const Ticket := preload("res://scripts/net/ticket.gd")
const NetConfig := preload("res://scripts/net/net_config.gd")

const DEFAULT_PORT := 9080
## Upper bound of frames a second: the rooms' tick loop is clocked by time, this only keeps the process off the CPU.
const MAX_FPS := 240

var host: Host
var listener: WsServer
var region: String = ""
var _stop_at_ms: int = -1
var _report_at_ms: int = 0


func _initialize() -> void:
	var port := DEFAULT_PORT
	var key := OS.get_environment("FUEL_SERVER_KEY")
	var dev := false
	var private_rooms := true
	var max_seconds := -1
	var tuning := {}
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--port="):
			port = argument.trim_prefix("--port=").to_int()
		elif argument.begins_with("--region="):
			region = argument.trim_prefix("--region=")
		elif argument.begins_with("--key="):
			key = argument.trim_prefix("--key=")
		elif argument.begins_with("--race-px="):
			tuning["race_finish_px"] = argument.trim_prefix("--race-px=").to_float()
		elif argument.begins_with("--races="):
			tuning["match_races"] = argument.trim_prefix("--races=").to_float()
		elif argument.begins_with("--max-seconds="):
			max_seconds = argument.trim_prefix("--max-seconds=").to_int()
		elif argument == "--dev":
			dev = true
		elif argument == "--no-private":
			private_rooms = false
	if key.is_empty() and not dev:
		printerr("server: no ticket key: give --key=SECRET (or FUEL_SERVER_KEY), or --dev for development")
		quit(2)
		return
	Engine.max_fps = MAX_FPS
	host = Host.new()
	host.region = region
	host.allow_private = private_rooms
	host.verifier = Ticket.new(key, dev)
	host.on_result = _on_result
	host.room_defaults = {"cfg": NetConfig.encode(tuning)}
	listener = WsServer.new()
	var error := listener.listen(port)
	if error != OK:
		printerr("server: cannot listen on port %d (error %d)" % [port, error])
		quit(3)
		return
	if max_seconds >= 0:
		_stop_at_ms = Time.get_ticks_msec() + max_seconds * 1000
	print("server: listening on port %d, region '%s'%s" % [port, region, ", DEV tickets accepted" if dev else ""])


func _process(_delta: float) -> bool:
	if host == null:
		return false
	var now := Time.get_ticks_msec()
	listener.poll(now)
	var connection := listener.take()
	while connection != null:
		host.accept(connection, now)
		connection = listener.take()
	host.poll(now)
	if now >= _report_at_ms:
		_report_at_ms = now + 60000
		print("server: %d rooms, %d connecting, %s" % [host.rooms.size(), host.pending_count(), host.counters])
	if _stop_at_ms >= 0 and now >= _stop_at_ms:
		print("server: stopping")
		quit(0)
	return false


func _on_result(result: Dictionary, replay: PackedByteArray) -> void:
	print("result: ", JSON.stringify(result))
	DirAccess.make_dir_recursive_absolute("user://replays")
	var file := FileAccess.open("user://replays/%s.rpl" % result["match_id"], FileAccess.WRITE)
	if file != null:
		file.store_buffer(replay)
