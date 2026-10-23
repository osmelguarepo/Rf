extends RefCounted
## The game server's side of its conversation with the API (docs/SPEC_ONLINE.md §16.2, backend/README.md):
##
## - Identity. The server has an id and a key (64 hex characters, given when it was registered); every call it makes carries
##   `X-Server-Id` and the key as the bearer. The same key signs the match tickets (match_ticket.gd).
## - Registration (register()): an operator's one-time call with the registration token; the API answers with the server's id and
##   key, shown once. Registering a name again rotates the key, so a server that has a key never registers by itself.
## - Heartbeat: every HEARTBEAT_EVERY_MS a POST /servers/heartbeat with the capacity, the matches under way, the drain flag and a
##   few metrics renews the lease (the API frees the players of a server that falls silent). The reply may ask the server to
##   drain (`draining`): the host then takes no new match and the server can stop when its rooms are done.
## - Results and replays go through outbox.gd, with the same ApiClient.
##
## `draining` is also set by drain() (a local request: a signal, an operator).

const ApiClient := preload("res://scripts/net/api_client.gd")
const Result := preload("res://scripts/net/api_result.gd")
const Host := preload("res://scripts/server/host.gd")
const NetConfig := preload("res://scripts/net/net_config.gd")

const HEARTBEAT_EVERY_MS := 10000

var api: ApiClient
var host: Host
var capacity: int = Host.MAX_ROOMS
var heartbeats_ok: int = 0
var heartbeats_failed: int = 0
var lease_seconds: int = 0
var last_error: String = ""
## Set by drain(); the reply's flag can set the host's too.
var drain_requested: bool = false

var _next_ms: int = 0
var _sim_hash: String = str(NetConfig.sim_hash())
var _inflight: bool = false


func _init(p_api: ApiClient, p_host: Host) -> void:
	api = p_api
	host = p_host


## Authenticates the server's calls from now on.
func set_identity(server_id: String, key_hex: String) -> void:
	api.token = key_hex
	api.extra_headers = PackedStringArray(["X-Server-Id: " + server_id])


## POST /servers/register with the operator's token. `done` takes {"ok", "server_id", "key", "message"}.
func register(operator_token: String, server_name: String, region: String, url: String, p_capacity: int, done: Callable) -> void:
	var saved := api.token
	api.token = operator_token
	api.extra_headers = PackedStringArray()
	api.request("POST", "servers/register", {"name": server_name, "region": region, "url": url, "capacity": p_capacity}, func(r: Result) -> void:
		var body := r.dict()
		var out := {"ok": r.ok, "server_id": str(body.get("server_id", "")), "key": str(body.get("key", "")), "message": r.message}
		if r.ok:
			set_identity(out["server_id"], out["key"])
		else:
			api.token = saved
		done.call(out))


## Asks the host to finish what it has and take nothing new.
func drain() -> void:
	drain_requested = true
	host.draining = true


## True when this server is draining and has no match left: it can stop.
func drained() -> bool:
	return host.draining and host.active_matches() == 0


## Once per frame.
func update(now_ms: int) -> void:
	if _inflight or now_ms < _next_ms:
		return
	_next_ms = now_ms + HEARTBEAT_EVERY_MS
	_inflight = true
	var counters: Dictionary = {"rooms": host.active_matches(), "connecting": host.pending_count()}
	for key: String in host.counters:
		counters[key] = int(host.counters[key])
	api.request("POST", "servers/heartbeat", {
		"capacity": capacity, "active_matches": host.active_matches(), "draining": host.draining,
		"sim_hash": _sim_hash, "game_version": NetConfig.GAME_VERSION, "metrics": counters,
	}, _on_heartbeat)


func _on_heartbeat(r: Result) -> void:
	_inflight = false
	if not r.ok:
		heartbeats_failed += 1
		last_error = r.error
		return
	heartbeats_ok += 1
	last_error = ""
	var body := r.dict()
	lease_seconds = int(body.get("lease_seconds", lease_seconds))
	if bool(body.get("draining", false)):
		drain_requested = true
		host.draining = true
