extends "res://tests/test_case.gd"
## The game server's mailbox and link to the API (scripts/server/outbox.gd, api_link.gd): results and replays are written to disk
## first and sent again, with growing waits, until the API accepts them (409 counts as accepted); the heartbeat reports capacity and
## obeys the drain flag; registration returns the key once.

const ApiClient := preload("res://scripts/net/api_client.gd")
const Outbox := preload("res://scripts/server/outbox.gd")
const ApiLink := preload("res://scripts/server/api_link.gd")
const Host := preload("res://scripts/server/host.gd")
const FakeHttp := preload("res://tests/fake_http.gd")

const DIR := "user://test_outbox"

var http: FakeHttp
var api: ApiClient
var box: Outbox
var now: int = 0


func before_each() -> void:
	_wipe()
	http = FakeHttp.new()
	api = ApiClient.new(http, "https://play.example/api")
	api.token = "00ff"
	api.extra_headers = PackedStringArray(["X-Server-Id: 7"])
	box = Outbox.new(api, DIR)
	now = 0


func after_each() -> void:
	_wipe()


func _wipe() -> void:
	for sub: String in ["", "/failed"]:
		if not DirAccess.dir_exists_absolute(DIR + sub):
			continue
		for file in DirAccess.get_files_at(DIR + sub):
			DirAccess.remove_absolute(DIR + sub + "/" + file)
	DirAccess.remove_absolute(DIR + "/failed")
	DirAccess.remove_absolute(DIR)


func _tick(ms: int = 100) -> void:
	now += ms
	box.update(now)
	api.poll()


func _result() -> Dictionary:
	return {"players": [{"player_id": "9007199254740993", "place": 2, "abandoned": false}], "final_checksum": "abc"}


func test_a_result_is_written_to_disk_then_sent_with_the_server_key_and_removed_once_accepted() -> void:
	http.on("POST", "/matches/55/result", 200, {"ok": true})
	box.put_result("55", _result())
	assert_true(FileAccess.file_exists(DIR + "/55.result.json"), "on disk before anything is sent")
	assert_eq(box.pending(), 1)
	_tick()
	_tick()
	var sent := http.sent("POST", "/matches/55/result")
	assert_eq(sent.size(), 1)
	assert_eq(FakeHttp.header_of(sent[0], "X-Server-Id"), "7")
	assert_eq(FakeHttp.header_of(sent[0], "Authorization"), "Bearer 00ff")
	assert_has(sent[0]["text"], "9007199254740993")
	assert_eq(FakeHttp.json_of(sent[0])["players"][0]["place"], 2.0)
	assert_eq(box.pending(), 0)
	assert_false(FileAccess.file_exists(DIR + "/55.result.json"), "accepted: the file goes")
	assert_eq(box.sent, 1)


func test_a_replay_goes_as_the_body_with_its_format() -> void:
	http.on("POST", "/matches/55/replay", 201, {"ok": true, "stored": true})
	box.put_replay("55", PackedByteArray([1, 2, 3, 4]))
	_tick()
	_tick()
	var sent := http.sent("POST", "/matches/55/replay")
	assert_eq(sent[0]["body"], PackedByteArray([1, 2, 3, 4]))
	assert_eq(FakeHttp.header_of(sent[0], "X-Replay-Format"), Outbox.REPLAY_FORMAT)
	assert_eq(box.pending(), 0)


func test_a_failure_is_tried_again_with_a_growing_wait_until_it_is_accepted() -> void:
	http.on("POST", "/matches/55/result", 503, {"error": "down"})
	http.on("POST", "/matches/55/result", 0, "")
	http.on("POST", "/matches/55/result", 200, {"ok": true})
	box.put_result("55", _result())
	_tick()
	_tick()
	assert_eq(http.sent("POST", "/matches/55/result").size(), 1)
	assert_eq(box.pending(), 1, "kept")
	_tick(Outbox.RETRY_MS - 300)
	assert_eq(http.sent("POST", "/matches/55/result").size(), 1, "not before the wait is over")
	_tick(500)
	_tick()
	assert_eq(http.sent("POST", "/matches/55/result").size(), 2)
	_tick(Outbox.RETRY_MS * 2 - 300)
	assert_eq(http.sent("POST", "/matches/55/result").size(), 2, "twice as long the second time")
	_tick(500)
	_tick()
	assert_eq(http.sent("POST", "/matches/55/result").size(), 3)
	assert_eq(box.pending(), 0, "the third try was accepted")
	assert_true(DirAccess.get_files_at(DIR).is_empty())


func test_the_wait_doubles_up_to_a_ceiling() -> void:
	assert_eq(Outbox.wait_ms(1), Outbox.RETRY_MS)
	assert_eq(Outbox.wait_ms(2), Outbox.RETRY_MS * 2)
	assert_eq(Outbox.wait_ms(3), Outbox.RETRY_MS * 4)
	assert_eq(Outbox.wait_ms(30), Outbox.MAX_WAIT_MS)


func test_a_409_means_the_api_already_has_a_result_and_the_item_is_done() -> void:
	http.on("POST", "/matches/55/result", 409, {"error": "conflict"})
	box.put_result("55", _result())
	_tick()
	_tick()
	assert_eq(box.pending(), 0)
	assert_false(FileAccess.file_exists(DIR + "/55.result.json"))
	assert_eq(http.sent("POST", "/matches/55/result").size(), 1, "and it is not sent again")


func test_a_match_the_api_does_not_know_is_set_aside_after_a_few_tries() -> void:
	http.on("POST", "/matches/66/result", 404, {"error": "not_found"})
	box.put_result("66", _result())
	for i in 12:
		_tick(Outbox.MAX_WAIT_MS)
	assert_eq(http.sent("POST", "/matches/66/result").size(), Outbox.MAX_REJECTED)
	assert_eq(box.pending(), 0)
	assert_eq(box.abandoned, 1)
	assert_true(FileAccess.file_exists(DIR + "/failed/66.result.json"), "kept for a person to read")


func test_what_a_previous_run_left_is_sent_after_a_restart() -> void:
	box.put_result("70", _result())
	box.put_replay("70", PackedByteArray([9, 9]))
	var restarted := Outbox.new(api, DIR)
	restarted.load_existing()
	assert_eq(restarted.pending(), 2)
	http.on("POST", "/matches/70/result", 200, {})
	http.on("POST", "/matches/70/replay", 200, {})
	now += 10
	restarted.update(now)
	api.poll()
	assert_eq(restarted.pending(), 0)
	assert_eq(http.sent("POST", "/matches/70/result").size(), 1)
	assert_eq(http.sent("POST", "/matches/70/replay").size(), 1)


func test_two_matches_do_not_wait_for_each_other() -> void:
	http.on("POST", "/matches/1/result", 503, {})
	http.on("POST", "/matches/2/result", 200, {})
	box.put_result("1", _result())
	box.put_result("2", _result())
	_tick()
	_tick()
	assert_eq(box.pending(), 1)
	assert_eq(box.items[0]["match_id"], "1")


# --- The link ---------------------------------------------------------------------------------------------------------------


func _link() -> ApiLink:
	var host := Host.new()
	return ApiLink.new(api, host)


func test_the_heartbeat_reports_capacity_matches_and_metrics_every_ten_seconds() -> void:
	http.on("POST", "/servers/heartbeat", 200, {"ok": true, "lease_seconds": 30})
	var link := _link()
	link.capacity = 250
	link.update(0)
	api.poll()
	var sent := http.sent("POST", "/servers/heartbeat")
	assert_eq(sent.size(), 1)
	var body: Dictionary = FakeHttp.json_of(sent[0])
	assert_eq(body["capacity"], 250.0)
	assert_eq(body["active_matches"], 0.0)
	assert_eq(body["draining"], false)
	assert_eq(body["game_version"], "0.2.0")
	assert_true((body["sim_hash"] as String).is_valid_int(), "the hash as text")
	assert_true(body["metrics"] is Dictionary)
	assert_eq(FakeHttp.header_of(sent[0], "X-Server-Id"), "7")
	assert_eq(link.lease_seconds, 30)
	assert_eq(link.heartbeats_ok, 1)
	link.update(ApiLink.HEARTBEAT_EVERY_MS - 1)
	assert_eq(http.sent("POST", "/servers/heartbeat").size(), 1)
	link.update(ApiLink.HEARTBEAT_EVERY_MS)
	assert_eq(http.sent("POST", "/servers/heartbeat").size(), 2)


func test_a_heartbeat_that_fails_is_counted_and_tried_again_next_time() -> void:
	var link := _link()
	link.update(0)
	api.poll()
	assert_eq(link.heartbeats_failed, 1)
	assert_eq(link.last_error, "network")
	http.on("POST", "/servers/heartbeat", 200, {"ok": true, "lease_seconds": 30})
	link.update(ApiLink.HEARTBEAT_EVERY_MS)
	api.poll()
	assert_eq(link.heartbeats_ok, 1)
	assert_eq(link.last_error, "")


func test_the_drain_flag_in_the_reply_stops_new_matches_and_lets_the_server_finish() -> void:
	http.on("POST", "/servers/heartbeat", 200, {"ok": true, "lease_seconds": 30})
	http.on("POST", "/servers/heartbeat", 200, {"ok": true, "lease_seconds": 30, "draining": true})
	var link := _link()
	link.update(0)
	api.poll()
	assert_false(link.host.draining)
	assert_false(link.drained())
	link.update(ApiLink.HEARTBEAT_EVERY_MS)
	api.poll()
	assert_true(link.host.draining)
	assert_true(link.drained(), "no match left: it can stop")
	link.update(ApiLink.HEARTBEAT_EVERY_MS * 2)
	assert_true(FakeHttp.json_of(http.sent("POST", "/servers/heartbeat")[2])["draining"], "and it says so")


func test_registration_returns_the_key_once_and_the_link_uses_it() -> void:
	api.token = ""
	api.extra_headers = PackedStringArray()
	http.on("POST", "/servers/register", 201, {"server_id": "12", "key": "ab".repeat(32), "key_version": 1})
	http.on("POST", "/servers/heartbeat", 200, {"ok": true, "lease_seconds": 30})
	var link := _link()
	var answers: Array[Dictionary] = []
	link.register("operator-token", "eu1", "eu", "wss://eu.play.example", 400, func(a: Dictionary) -> void: answers.append(a))
	api.poll()
	var sent := http.sent("POST", "/servers/register")[0]
	assert_eq(FakeHttp.header_of(sent, "Authorization"), "Bearer operator-token")
	assert_eq(FakeHttp.json_of(sent), {"name": "eu1", "region": "eu", "url": "wss://eu.play.example", "capacity": 400.0})
	assert_eq(answers[0]["ok"], true)
	assert_eq(answers[0]["server_id"], "12")
	assert_eq(answers[0]["key"], "ab".repeat(32))
	link.update(0)
	api.poll()
	var beat := http.sent("POST", "/servers/heartbeat")[0]
	assert_eq(FakeHttp.header_of(beat, "X-Server-Id"), "12")
	assert_eq(FakeHttp.header_of(beat, "Authorization"), "Bearer " + "ab".repeat(32))
	http.set_route("POST", "/servers/register", 401, {"error": "unauthorized", "message": "registration token required"})
	var refused: Array[Dictionary] = []
	link.register("bad", "eu1", "eu", "wss://x", 1, func(a: Dictionary) -> void: refused.append(a))
	api.poll()
	assert_eq(refused[0]["ok"], false)
