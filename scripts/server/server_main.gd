extends SceneTree
## The game server's entry point (docs/SPEC_ONLINE.md §3, §11, §16.1 10). Headless, one process, many rooms:
##
##   godot --headless --path . -s res://scripts/server/server_main.gd -- --port=9080 --region=eu --key=SECRET [--dev]
##
## --port      TCP port the WebSocket listener binds (default 9080). A proxy (Caddy) terminates TLS in front of it.
## --region    a label for the logs (the matchmaker will use it).
## --key       this server's key, 64 hex characters (or the FUEL_SERVER_KEY environment variable): it signs the API's match tickets
##              (backend/docs/TICKET.md) and authenticates the server to the API. Each server has its own.
## --server-id  the server's id as the API knows it (FUEL_SERVER_ID): ticket server ids must equal it; sent as X-Server-Id.
## --api=URL    the API (FUEL_API_URL): the server sends a heartbeat (capacity, matches, drain flag, metrics) every 10 s, and the
##              result and replay of each match through a disk outbox (user://outbox) that retries until the API accepts them.
##              Without it the server runs on its own: no results leave the process.
## --register-token=TOKEN --public-url=wss://...  with --server-id as the name and no --key: registers with the API at start-up
##              (the key is printed once; keep it: registering again rotates it).
## --capacity=N  the matches this server says it can hold (default MAX_ROOMS).
## --exit-when-drained  stop once the API asked to drain and no match is left.
## --dev        accept the stand-in text tickets ("dev." unsigned, "v1." HMAC) and run without a key. Never in production.
## --no-private  refuse private rooms.
## --race-px=N, --races=N  shorter races for a try-out (the match's rules, sent to every client in WELCOME).
## --max-seconds=N  stop after N seconds (tools and tests).
## Every match that ends prints one "result: {...}" line (JSON, SteamIDs as text) and saves its replay to user://replays/.

const Host := preload("res://scripts/server/host.gd")
const WsServer := preload("res://scripts/net/ws_server.gd")
const Ticket := preload("res://scripts/net/ticket.gd")
const MatchTicket := preload("res://scripts/net/match_ticket.gd")
const ApiClient := preload("res://scripts/net/api_client.gd")
const HttpRequestTransport := preload("res://scripts/net/http_request_transport.gd")
const ApiLink := preload("res://scripts/server/api_link.gd")
const Outbox := preload("res://scripts/server/outbox.gd")
const NetConfig := preload("res://scripts/net/net_config.gd")

const DEFAULT_PORT := 9080
## Upper bound of frames a second: the rooms' tick loop is clocked by time, this only keeps the process off the CPU.
const MAX_FPS := 240

var host: Host
var listener: WsServer
var region: String = ""
var api: ApiClient = null
var link: ApiLink = null
var outbox: Outbox = null
var exit_when_drained: bool = false
var _server_id: String = ""
var _dev: bool = false
var _stop_at_ms: int = -1
var _report_at_ms: int = 0


func _initialize() -> void:
	var port := DEFAULT_PORT
	var key := OS.get_environment("FUEL_SERVER_KEY")
	var api_url := OS.get_environment("FUEL_API_URL")
	var register_token := OS.get_environment("FUEL_REGISTER_TOKEN")
	var public_url := ""
	var capacity := Host.MAX_ROOMS
	_server_id = OS.get_environment("FUEL_SERVER_ID")
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
		elif argument.begins_with("--api="):
			api_url = argument.trim_prefix("--api=")
		elif argument.begins_with("--server-id="):
			_server_id = argument.trim_prefix("--server-id=")
		elif argument.begins_with("--register-token="):
			register_token = argument.trim_prefix("--register-token=")
		elif argument.begins_with("--public-url="):
			public_url = argument.trim_prefix("--public-url=")
		elif argument.begins_with("--capacity="):
			capacity = argument.trim_prefix("--capacity=").to_int()
		elif argument == "--exit-when-drained":
			exit_when_drained = true
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
	var registering := key.is_empty() and not register_token.is_empty() and not api_url.is_empty()
	if key.is_empty() and not dev and not registering:
		printerr("server: no ticket key: give --key=HEX (or FUEL_SERVER_KEY), --register-token with --api, or --dev for development")
		quit(2)
		return
	_dev = dev
	Engine.max_fps = MAX_FPS
	host = Host.new()
	host.region = region
	host.allow_private = private_rooms
	host.verifier = Ticket.new(key, dev)
	host.legacy_enabled = dev
	host.match_verifier = MatchTicket.new(key, _server_id)
	host.on_result = _on_result
	if not api_url.is_empty():
		api = ApiClient.new(HttpRequestTransport.new(root), api_url)
		link = ApiLink.new(api, host)
		link.capacity = capacity
		outbox = Outbox.new(api)
		if not registering:
			link.set_identity(_server_id, key)
			outbox.load_existing()
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
	if registering:
		link.register(register_token, _server_id, region, public_url, capacity, _on_registered)


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
	if api != null:
		api.poll()
		if link.api.logged_in() and (link.api.extra_headers.size() > 0):
			link.update(now)
			outbox.update(now)
		if exit_when_drained and link.drained() and outbox.pending() == 0:
			print("server: drained")
			quit(0)
	if now >= _report_at_ms:
		_report_at_ms = now + 60000
		print("server: %d rooms, %d connecting, %s" % [host.rooms.size(), host.pending_count(), host.counters])
	if _stop_at_ms >= 0 and now >= _stop_at_ms:
		print("server: stopping")
		quit(0)
	return false


func _on_registered(answer: Dictionary) -> void:
	if not answer["ok"]:
		printerr("server: registration refused: ", answer["message"])
		quit(4)
		return
	_server_id = answer["server_id"]
	host.match_verifier = MatchTicket.new(answer["key"], _server_id)
	outbox.load_existing()
	print("server: registered as id %s; the key is %s (shown once: keep it as FUEL_SERVER_KEY)" % [_server_id, answer["key"]])


func _on_result(result: Dictionary, replay: PackedByteArray) -> void:
	print("result: ", JSON.stringify(result))
	if outbox != null:
		var body := Outbox.result_body(result)
		if not body.is_empty():
			outbox.put_result(str(result["match_id"]), body)
			outbox.put_replay(str(result["match_id"]), replay)
	DirAccess.make_dir_recursive_absolute("user://replays")
	var file := FileAccess.open("user://replays/%s.rpl" % result["match_id"], FileAccess.WRITE)
	if file != null:
		file.store_buffer(replay)
