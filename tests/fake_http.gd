extends "res://scripts/net/http_transport.gd"
## An HttpTransport for the tests of the API client, the login, the queue and the game server's link: it never touches a network.
## Every request is recorded in `requests` ({id, method, url, headers, text, body}); the answer comes from the first route that
## matches (method and the URL's end), as a recorded response. A route with several responses gives them in order and then
## repeats the last. No route: status 0, as a network failure. With `hold` the answers wait until release().
##
## Not a test file.

## {"method", "suffix", "responses": [{"status", "body" (String or Variant for JSON), "headers"}]}
var routes: Array[Dictionary] = []
var requests: Array[Dictionary] = []
var hold: bool = false
var _done: Array[Dictionary] = []
var _held: Array[Dictionary] = []
var _next_id: int = 1


## Adds a route. `body` is a String (sent as it is) or any JSON-able value.
func on(method: String, suffix: String, status: int, body: Variant = {}, headers: PackedStringArray = PackedStringArray()) -> void:
	for route in routes:
		if route["method"] == method and route["suffix"] == suffix:
			(route["responses"] as Array).append({"status": status, "body": body, "headers": headers})
			return
	routes.append({"method": method, "suffix": suffix, "responses": [{"status": status, "body": body, "headers": headers}], "used": 0})


## Replaces the responses of a route with one.
func set_route(method: String, suffix: String, status: int, body: Variant = {}) -> void:
	routes = routes.filter(func(route: Dictionary) -> bool: return not (route["method"] == method and route["suffix"] == suffix))
	on(method, suffix, status, body)


func request(method: String, url: String, headers: PackedStringArray, body: PackedByteArray) -> int:
	var id := _next_id
	_next_id += 1
	requests.append({"id": id, "method": method, "url": url, "headers": headers, "text": body.get_string_from_utf8(), "body": body})
	var answer := {"id": id, "status": 0, "headers": PackedStringArray(), "body": PackedByteArray()}
	for route in routes:
		if route["method"] == method and url.ends_with(route["suffix"]):
			var responses: Array = route["responses"]
			var chosen: Dictionary = responses[mini(int(route["used"]), responses.size() - 1)]
			route["used"] = int(route["used"]) + 1
			answer["status"] = chosen["status"]
			answer["headers"] = chosen["headers"]
			var payload: Variant = chosen["body"]
			answer["body"] = (payload as String).to_utf8_buffer() if payload is String else JSON.stringify(payload).to_utf8_buffer()
			break
	if hold:
		_held.append(answer)
	else:
		_done.append(answer)
	return id


func poll() -> Array[Dictionary]:
	var out := _done
	_done = []
	return out


## Lets the answers that were held come in.
func release() -> void:
	_done.append_array(_held)
	_held = []


## The recorded requests with this method and a URL ending in `suffix`.
func sent(method: String, suffix: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for r in requests:
		if r["method"] == method and (r["url"] as String).ends_with(suffix):
			out.append(r)
	return out


## The JSON body of a recorded request.
static func json_of(r: Dictionary) -> Variant:
	return JSON.parse_string(r["text"])


static func header_of(r: Dictionary, name: String) -> String:
	for line: String in r["headers"]:
		if line.to_lower().begins_with(name.to_lower() + ":"):
			return line.substr(name.length() + 1).strip_edges()
	return ""
