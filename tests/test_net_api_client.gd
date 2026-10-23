extends "res://tests/test_case.gd"
## The API client (scripts/net/api_client.gd): the base URL, the bearer token, JSON in and out with ids kept as text (a SteamID or a
## seed beyond 2^53 never becomes a float), errors as Result objects, and the HTTP transport's fake.

const ApiClient := preload("res://scripts/net/api_client.gd")
const Result := preload("res://scripts/net/api_result.gd")
const FakeHttp := preload("res://tests/fake_http.gd")

var http: FakeHttp
var api: ApiClient
var got: Array[Result] = []


func before_each() -> void:
	http = FakeHttp.new()
	api = ApiClient.new(http, "https://play.example/api/")
	got = []


func _take(r: Result) -> void:
	got.append(r)


func test_the_base_url_comes_from_the_argument_then_the_setting_then_the_page() -> void:
	assert_eq(ApiClient.resolve_base_url(PackedStringArray(["--api=http://a:1/x/"]), "http://s", "https://o"), "http://a:1/x")
	assert_eq(ApiClient.resolve_base_url(PackedStringArray(), "http://s/", "https://o"), "http://s")
	assert_eq(ApiClient.resolve_base_url(PackedStringArray(), "", "https://o.example/"), "https://o.example/api", "the web page's origin")
	assert_eq(ApiClient.resolve_base_url(PackedStringArray(["--api="]), "", ""), ApiClient.DEFAULT_URL, "an empty argument is no argument")
	assert_eq(ApiClient.join_url("https://x/api/", "/me"), "https://x/api/me")


func test_a_call_goes_to_the_base_url_with_the_token_and_a_json_body() -> void:
	api.token = "tok123"
	api.request("POST", "queue", {"latencies": {"eu": 42}}, _take)
	assert_eq(http.requests.size(), 1)
	var sent := http.requests[0]
	assert_eq(sent["method"], "POST")
	assert_eq(sent["url"], "https://play.example/api/queue")
	assert_eq(FakeHttp.header_of(sent, "Authorization"), "Bearer tok123")
	assert_eq(FakeHttp.header_of(sent, "Content-Type"), "application/json")
	assert_eq(FakeHttp.json_of(sent), {"latencies": {"eu": 42.0}})
	api.token = ""
	api.request("GET", "me", null, _take)
	assert_eq(FakeHttp.header_of(http.requests[1], "Authorization"), "", "no token, no header")
	assert_eq(http.requests[1]["text"], "", "and no body for a GET")


func test_ids_beyond_2_pow_53_stay_exact_text() -> void:
	var steam_id := "76561198000000001"
	var seed_text := "9223372036854775807"
	api.request("POST", "auth/steam", {"ticket": "ab", "steam_id": steam_id}, _take)
	assert_has(http.requests[0]["text"], steam_id, "sent as text, digit for digit")
	http.on("GET", "/me", 200, '{"steam_id": "%s", "player_id": "9223372036854775806", "seed": 9223372036854775807, "points": 1250, "ids": [12345678901234567, 5]}' % steam_id)
	api.request("GET", "me", null, _take)
	api.poll()
	assert_eq(got.size(), 2)
	var d := got[1].dict()
	assert_eq(d["steam_id"], steam_id)
	assert_eq(d["player_id"], "9223372036854775806")
	assert_eq(d["seed"], seed_text, "a bare number a double cannot hold becomes text")
	assert_eq(d["points"], 1250, "a small whole number is an int, not 1250.0")
	assert_eq(d["ids"], ["12345678901234567", 5])
	assert_eq(str(int(d["seed"])), seed_text, "and it still converts exactly")


func test_whole_numbers_become_ints_and_fractions_stay() -> void:
	assert_eq(ApiClient.parse_json('{"a": 3, "b": 2.5, "c": [1, 2.0], "d": {"e": 7}}'), {"a": 3, "b": 2.5, "c": [1, 2], "d": {"e": 7}})
	assert_null(ApiClient.parse_json("not json {"))
	assert_eq(ApiClient.parse_json('{"s": "a: 12345678901234567, b"}'), {"s": "a: 12345678901234567, b"}, "text inside a string is left alone")


func test_a_success_gives_the_data() -> void:
	http.on("GET", "/leaderboard?limit=5", 200, {"entries": [{"rank": 1, "name": "ANA", "points": 900}]})
	api.request("GET", "leaderboard?limit=5", null, _take)
	api.poll()
	assert_true(got[0].ok)
	assert_eq(got[0].status, 200)
	assert_false(got[0].network)
	assert_eq(got[0].dict()["entries"][0]["name"], "ANA")


func test_an_api_error_gives_its_code_and_message() -> void:
	http.on("POST", "/auth/steam", 403, {"error": "banned", "message": "this Steam account is banned"})
	api.request("POST", "auth/steam", {"ticket": "x"}, _take)
	api.poll()
	var r := got[0]
	assert_false(r.ok)
	assert_eq(r.status, 403)
	assert_eq(r.error, "banned")
	assert_eq(r.message, "this Steam account is banned")
	assert_false(r.network)


func test_no_answer_is_a_network_failure_not_a_crash() -> void:
	api.request("GET", "me", null, _take)
	api.poll()
	assert_false(got[0].ok)
	assert_true(got[0].network)
	assert_eq(got[0].error, "network")
	var nothing := ApiClient.new(null)
	nothing.request("GET", "me", null, _take)
	assert_eq(got.size(), 2, "without a transport the callback still runs")
	assert_true(got[1].network)


func test_a_non_json_error_body_still_gives_a_result() -> void:
	http.on("GET", "/me", 502, "<html>Bad gateway</html>")
	api.request("GET", "me", null, _take)
	api.poll()
	assert_eq(got[0].status, 502)
	assert_eq(got[0].error, "http_502")
	assert_null(got[0].data)


func test_retry_after_comes_from_the_header_or_the_body() -> void:
	http.on("POST", "/queue", 429, {"error": "penalty"}, PackedStringArray(["Retry-After: 120"]))
	api.request("POST", "queue", {}, _take)
	http.on("POST", "/auth/guest", 429, {"error": "rate_limited", "retry_after_s": 30})
	api.request("POST", "auth/guest", {}, _take)
	api.poll()
	assert_eq(got[0].retry_after_s, 120)
	assert_eq(got[1].retry_after_s, 30)


func test_answers_reach_their_own_callbacks_and_only_once() -> void:
	http.on("GET", "/a", 200, {"n": 1})
	http.on("GET", "/b", 200, {"n": 2})
	var order: Array[int] = []
	api.request("GET", "a", null, func(r: Result) -> void: order.append(r.dict()["n"]))
	api.request("GET", "b", null, func(r: Result) -> void: order.append(r.dict()["n"]))
	assert_eq(api.busy(), 2)
	api.poll()
	api.poll()
	assert_eq(order, [1, 2])
	assert_eq(api.busy(), 0)


func test_a_server_sends_its_id_and_key_instead_of_a_token() -> void:
	api.token = "00ff"
	api.extra_headers = PackedStringArray(["X-Server-Id: 7"])
	api.request_bytes("POST", "matches/5/replay", PackedByteArray([1, 2, 3]), PackedStringArray(["X-Replay-Format: godot-replay-1"]), _take)
	var sent := http.requests[0]
	assert_eq(FakeHttp.header_of(sent, "X-Server-Id"), "7")
	assert_eq(FakeHttp.header_of(sent, "Authorization"), "Bearer 00ff")
	assert_eq(FakeHttp.header_of(sent, "X-Replay-Format"), "godot-replay-1")
	assert_eq(FakeHttp.header_of(sent, "Content-Type"), "application/octet-stream")
	assert_eq(sent["body"], PackedByteArray([1, 2, 3]))
	api.request_url("GET", "https://other.example/healthz", null, _take, false)
	assert_eq(FakeHttp.header_of(http.requests[1], "Authorization"), "", "a probe to another host carries no secret")
