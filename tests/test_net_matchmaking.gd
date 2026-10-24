extends "res://tests/test_case.gd"
## The queue's state machine (scripts/net/matchmaking.gd) over a fake HTTP table and a virtual clock: latency probes, joining, the
## status poll, the ready check and its countdown, a match that falls through, cancelling, penalties, a dead session and a
## server that stops answering.

const ApiClient := preload("res://scripts/net/api_client.gd")
const Matchmaking := preload("res://scripts/net/matchmaking.gd")
const FakeHttp := preload("res://tests/fake_http.gd")

const M := Matchmaking.State

var http: FakeHttp
var api: ApiClient
var mm: Matchmaking
var now: int = 0
var unix: int = 1000


func before_each() -> void:
	http = FakeHttp.new()
	api = ApiClient.new(http, "https://play.example/api")
	api.token = "tok"
	mm = Matchmaking.new(api)
	now = 0
	unix = 1000
	mm.clock = func() -> int: return now
	mm.unix_clock = func() -> int: return unix
	http.on("GET", "/healthz", 200, {"ok": true})
	http.on("POST", "/queue", 200, {"queue_id": "123456789012345678"})
	http.on("DELETE", "/queue", 200, {})
	http.on("POST", "/queue/ready", 200, {})
	http.on("POST", "/match/9007199254740993/leave", 200, {})


## A frame: the app polls the API client, then the screen updates the queue; `ms` of time pass first.
func after_each() -> void:
	# The clocks are lambdas that hold this test: let go of them so nothing is left in a reference cycle.
	mm.clock = Callable()
	mm.unix_clock = Callable()


## A frame: the app polls the API client, then the screen updates the queue; `ms` of time pass first.
func _frames(count: int, ms: int = 100) -> void:
	for i in count:
		now += ms
		api.poll()
		mm.update(now)
		api.poll()


func _status(state: String, extra: Dictionary = {}) -> Dictionary:
	var body := {"state": state, "wait_s": 0, "band_divisions": 1, "players_found": 1}
	body.merge(extra, true)
	return body


func _to_waiting() -> void:
	mm.find_race()
	_frames(8)
	assert_eq(mm.state, M.WAITING, "the queue is joined")


func test_finding_a_race_measures_the_latency_and_joins_with_it() -> void:
	mm.find_race()
	assert_eq(mm.state, M.MEASURING)
	assert_eq(http.sent("GET", "/healthz").size(), 1, "one region, probed in turn")
	_frames(8)
	assert_eq(http.sent("GET", "/healthz").size(), Matchmaking.PROBES)
	assert_eq(mm.state, M.WAITING)
	var body: Dictionary = FakeHttp.json_of(http.sent("POST", "/queue")[0])
	assert_true(body["latencies"].has(Matchmaking.DEFAULT_REGION))
	assert_eq(FakeHttp.header_of(http.sent("GET", "/healthz")[0], "Authorization"), "", "probes carry no token")
	assert_eq(FakeHttp.header_of(http.sent("POST", "/queue")[0], "Authorization"), "Bearer tok")


func test_each_configured_region_is_pinged_at_its_own_address() -> void:
	mm.regions = {"eu": "https://eu.example", "us": "https://us.example/api"}
	http.on("GET", "https://eu.example/healthz", 200, {})
	http.on("GET", "https://us.example/api/healthz", 200, {})
	mm.find_race()
	_frames(10)
	assert_eq(http.sent("GET", "https://eu.example/healthz").size(), Matchmaking.PROBES)
	assert_eq(http.sent("GET", "https://us.example/api/healthz").size(), Matchmaking.PROBES)
	var body: Dictionary = FakeHttp.json_of(http.sent("POST", "/queue")[0])
	assert_eq((body["latencies"] as Dictionary).keys().size(), 2)


func test_a_region_that_does_not_answer_is_left_out_and_none_means_unavailable() -> void:
	http.routes = []
	http.on("POST", "/queue", 200, {})
	mm.regions = {"eu": "https://eu.example", "dead": "https://dead.example"}
	http.on("GET", "https://eu.example/healthz", 200, {})
	mm.find_race()
	_frames(10)
	var body: Dictionary = FakeHttp.json_of(http.sent("POST", "/queue")[0])
	assert_eq((body["latencies"] as Dictionary).keys(), ["eu"])
	var alone := Matchmaking.new(api)
	alone.regions = {"dead": "https://dead.example"}
	alone.find_race()
	for i in 6:
		api.poll()
	assert_eq(alone.state, M.FAILED)
	assert_eq(alone.message, "ONLINE UNAVAILABLE")


func test_the_status_poll_shows_the_wait_the_band_and_the_players() -> void:
	_to_waiting()
	http.on("GET", "/queue/status", 200, _status("waiting", {"wait_s": 12, "band_divisions": 2, "players_found": 3}))
	_frames(12)
	assert_eq(mm.state, M.WAITING)
	assert_eq(mm.wait_s, 12)
	assert_eq(mm.band_divisions, 2)
	assert_eq(mm.players_found, 3)
	assert_gt(http.sent("GET", "/queue/status").size(), 0)
	var polls := http.sent("GET", "/queue/status").size()
	_frames(30)
	assert_between(http.sent("GET", "/queue/status").size() - polls, 2, 4, "about one a second (3 s passed)")


func test_a_found_match_asks_to_accept_with_a_countdown_then_waits_for_the_others() -> void:
	_to_waiting()
	http.on("GET", "/queue/status", 200, _status("found", {"players_found": 4, "match": {"match_id": "9007199254740993", "ready_deadline_unix": 1020}}))
	_frames(12)
	assert_eq(mm.state, M.FOUND)
	assert_eq(mm.match_id, "9007199254740993", "the match id is text and exact")
	assert_eq(mm.countdown_s(), 20)
	unix = 1015
	assert_eq(mm.countdown_s(), 5)
	unix = 1100
	assert_eq(mm.countdown_s(), 0, "never negative")
	unix = 1005
	mm.accept()
	_frames(3)
	assert_eq(FakeHttp.json_of(http.sent("POST", "/queue/ready")[0]), {"match_id": "9007199254740993"})
	assert_eq(mm.state, M.READY)
	assert_true(mm.accepted)
	_frames(12)
	assert_eq(mm.state, M.READY, "the server still says found; we have accepted")
	http.set_route("GET", "/queue/status", 200, _status("ready", {"match": {"match_id": "9007199254740993", "ready_deadline_unix": 1020}}))
	_frames(12)
	assert_eq(mm.state, M.READY)


func test_accepting_is_only_possible_when_a_match_is_found() -> void:
	_to_waiting()
	mm.accept()
	_frames(2)
	assert_eq(http.sent("POST", "/queue/ready").size(), 0)


func test_starting_fetches_the_connection_and_joins() -> void:
	_to_waiting()
	http.on("GET", "/queue/status", 200, _status("starting", {"match": {"match_id": "9007199254740993", "ready_deadline_unix": 1020}}))
	http.on("GET", "/match/9007199254740993/join", 200, {"ws_url": "wss://eu.play.example/ws/1", "ticket": "AQAD-_abc"})
	_frames(30)
	assert_eq(mm.state, M.JOINED)
	assert_eq(mm.join, {"ws_url": "wss://eu.play.example/ws/1", "ticket": "AQAD-_abc"})
	assert_eq(http.sent("GET", "/match/9007199254740993/join").size(), 1, "asked once")


func test_the_join_is_tried_again_after_a_hiccup_and_gives_up_on_a_refusal() -> void:
	_to_waiting()
	http.on("GET", "/queue/status", 200, _status("starting", {"match": {"match_id": "9007199254740993", "ready_deadline_unix": 1020}}))
	http.on("GET", "/match/9007199254740993/join", 503, {"error": "busy"})
	http.on("GET", "/match/9007199254740993/join", 200, {"ws_url": "wss://x/ws", "ticket": "T"})
	_frames(60)
	assert_eq(mm.state, M.JOINED)
	assert_eq(http.sent("GET", "/match/9007199254740993/join").size(), 2)
	var refused := Matchmaking.new(api)
	refused.clock = mm.clock
	refused.state = M.STARTING
	refused.match_id = "55"
	http.on("GET", "/match/55/join", 404, {"error": "no_match", "message": "no such match"})
	refused.update(now + 5000)
	api.poll()
	assert_eq(refused.state, M.FAILED)


func test_a_match_that_falls_through_goes_back_to_searching() -> void:
	_to_waiting()
	http.on("GET", "/queue/status", 200, _status("found", {"match": {"match_id": "9007199254740993", "ready_deadline_unix": 1020}}))
	http.on("GET", "/queue/status", 200, _status("waiting", {"players_found": 1}))
	_frames(12)
	assert_eq(mm.state, M.FOUND)
	_frames(12)
	assert_eq(mm.state, M.WAITING)
	assert_eq(mm.message, "MATCH FELL THROUGH - SEARCHING AGAIN")
	assert_false(mm.accepted)


func test_an_idle_status_means_the_queue_ended() -> void:
	_to_waiting()
	http.on("GET", "/queue/status", 200, _status("idle"))
	_frames(12)
	assert_eq(mm.state, M.IDLE)
	assert_eq(mm.message, "LEFT THE QUEUE")
	http.set_route("GET", "/queue/status", 200, _status("waiting"))
	_to_waiting_again()
	http.set_route("GET", "/queue/status", 200, _status("found", {"match": {"match_id": "9007199254740993", "ready_deadline_unix": 1020}}))
	_frames(12)
	http.set_route("GET", "/queue/status", 200, _status("idle"))
	_frames(12)
	assert_eq(mm.state, M.IDLE)
	assert_eq(mm.message, "MATCH CANCELLED")


func _to_waiting_again() -> void:
	mm.find_race()
	_frames(8)


func test_cancelling_leaves_the_queue_and_ignores_late_answers() -> void:
	mm.find_race()
	http.hold = true
	_frames(2)
	mm.cancel()
	http.hold = false
	http.release()
	_frames(10)
	assert_eq(mm.state, M.IDLE, "a late probe does not revive the search")
	assert_eq(http.sent("POST", "/queue").size(), 0)
	_to_waiting()
	mm.cancel()
	_frames(2)
	assert_eq(http.sent("DELETE", "/queue").size(), 1)
	assert_eq(mm.state, M.IDLE)


func test_cancelling_after_the_connection_started_leaves_the_match() -> void:
	_to_waiting()
	http.on("GET", "/queue/status", 200, _status("starting", {"match": {"match_id": "9007199254740993", "ready_deadline_unix": 1020}}))
	http.on("GET", "/match/9007199254740993/join", 200, {"ws_url": "wss://x/ws", "ticket": "T"})
	_frames(30)
	assert_eq(mm.state, M.JOINED)
	mm.cancel()
	_frames(2)
	assert_eq(http.sent("POST", "/match/9007199254740993/leave").size(), 1)
	assert_eq(mm.state, M.IDLE)


func test_a_penalty_is_a_message_with_the_wait() -> void:
	http.set_route("POST", "/queue", 403, {"error": "queue_banned", "message": "x", "retry_after_s": 300})
	mm.find_race()
	_frames(8)
	assert_eq(mm.state, M.FAILED)
	assert_eq(mm.penalty_s, 300)
	assert_eq(mm.message, "YOU LEFT TOO MANY MATCHES - WAIT 5 MIN")
	assert_eq(Matchmaking.penalty_text(45), "YOU LEFT TOO MANY MATCHES - WAIT 45 S")
	assert_eq(Matchmaking.penalty_text(0), "YOU LEFT TOO MANY MATCHES - WAIT A WHILE")


func test_a_dead_session_is_reported() -> void:
	http.set_route("POST", "/queue", 401, {"error": "unauthorized"})
	mm.find_race()
	_frames(8)
	assert_eq(mm.state, M.FAILED)
	assert_eq(mm.error, "session_expired")


func test_a_server_that_stops_answering_fails_after_a_few_tries() -> void:
	_to_waiting()
	http.routes = http.routes.filter(func(route: Dictionary) -> bool: return route["suffix"] != "/queue/status")
	_frames(60)
	assert_eq(mm.state, M.FAILED)
	assert_eq(mm.message, "ONLINE UNAVAILABLE")


func test_one_hiccup_does_not_fail_the_search() -> void:
	_to_waiting()
	http.routes = http.routes.filter(func(route: Dictionary) -> bool: return route["suffix"] != "/queue/status")
	_frames(15)
	http.on("GET", "/queue/status", 200, _status("waiting", {"wait_s": 3}))
	_frames(25)
	assert_eq(mm.state, M.WAITING)
	assert_eq(mm.wait_s, 3)


func test_an_already_queued_player_resumes_the_search() -> void:
	http.set_route("POST", "/queue", 409, {"error": "already_queued"})
	mm.find_race()
	_frames(8)
	assert_eq(mm.state, M.WAITING)
