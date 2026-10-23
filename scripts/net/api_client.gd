extends RefCounted
## The client of the API (docs/SPEC_ONLINE.md §16.1; backend/README.md): JSON over an HttpTransport, one callback per call.
##
## - Base URL (resolve_base_url): `--api=URL` after the "--" of the command line, else the project setting `fuel/net/api_url`,
##   else, on the web, the page's own origin plus "/api" (the proxy mounts the API there: same origin, no CORS), else
##   DEFAULT_URL for development.
## - Session. `token` is the session token, held in memory only: it is sent as `Authorization: Bearer`. A game server sets
##   `extra_headers` instead (X-Server-Id and its key as the bearer).
## - Ids stay text. SteamIDs, player ids, match ids and seeds are strings in the API; a bare integer of 16 digits or more in a
##   response (which a double cannot hold) is turned into text before the JSON is parsed, and every other whole number becomes an
##   int, never a float. A body sent with request() is built with JSON.stringify(): put ids in it as Strings.
## - Results. Every call ends in a callback with a Result (api_result.gd): a network failure, an API error or the data; never a
##   crash. Callbacks run inside poll(), which the app calls once per frame.

const Result := preload("res://scripts/net/api_result.gd")
const HttpTransport := preload("res://scripts/net/http_transport.gd")

const DEFAULT_URL := "http://127.0.0.1:8080/api"
const SETTING := "fuel/net/api_url"
const ARGUMENT := "--api="
## Whole numbers up to this stay ints; the JSON parser gives doubles.
const MAX_SAFE := 9007199254740992.0

var base_url: String = DEFAULT_URL
var token: String = ""
var extra_headers: PackedStringArray = PackedStringArray()
var transport: HttpTransport = null
## Requests in flight: id -> callback.
var _pending: Dictionary = {}


func _init(p_transport: HttpTransport = null, p_base_url: String = DEFAULT_URL) -> void:
	transport = p_transport
	base_url = p_base_url.rstrip("/")


## The base URL from the command line arguments, the project setting and the web page's origin, in that order of preference.
static func resolve_base_url(args: PackedStringArray, setting: String, web_origin: String) -> String:
	for argument in args:
		if argument.begins_with(ARGUMENT) and argument.length() > ARGUMENT.length():
			return argument.trim_prefix(ARGUMENT).rstrip("/")
	if not setting.is_empty():
		return setting.rstrip("/")
	if not web_origin.is_empty():
		return web_origin.rstrip("/") + "/api"
	return DEFAULT_URL


static func join_url(base: String, path: String) -> String:
	return base.rstrip("/") + "/" + path.trim_prefix("/")


func logged_in() -> bool:
	return not token.is_empty()


func busy() -> int:
	return _pending.size()


## Forgets the calls still in flight (their callbacks never run): when the owner goes away, so callbacks that hold it do not keep it alive.
func drop_pending() -> void:
	_pending.clear()


## A call to the API: `body` is a Dictionary (sent as JSON), an Array, or null for none. `callback` takes a Result.
func request(method: String, path: String, body: Variant, callback: Callable) -> void:
	request_url(method, join_url(base_url, path), body, callback)


## The same to a full URL (the latency probes use it for other regions).
func request_url(method: String, url: String, body: Variant, callback: Callable, authenticated: bool = true) -> void:
	var headers := PackedStringArray()
	var bytes := PackedByteArray()
	if body != null:
		headers.append("Content-Type: application/json")
		bytes = JSON.stringify(body).to_utf8_buffer()
	_send(method, url, headers, bytes, callback, authenticated)


## A call with a raw body (a replay): `headers` are extra header lines.
func request_bytes(method: String, path: String, body: PackedByteArray, headers: PackedStringArray, callback: Callable,
		content_type: String = "application/octet-stream") -> void:
	var all := headers.duplicate()
	all.append("Content-Type: " + content_type)
	_send(method, join_url(base_url, path), all, body, callback, true)


func _send(method: String, url: String, headers: PackedStringArray, body: PackedByteArray, callback: Callable, authenticated: bool) -> void:
	if authenticated:
		if not token.is_empty():
			headers.append("Authorization: Bearer " + token)
		headers.append_array(extra_headers)
	if transport == null:
		callback.call(Result.failure("network", "no transport"))
		return
	var id := transport.request(method, url, headers, body)
	_pending[id] = callback


## Delivers the finished calls to their callbacks. Once per frame.
func poll() -> void:
	if transport == null:
		return
	for done in transport.poll():
		var callback: Variant = _pending.get(done["id"])
		_pending.erase(done["id"])
		if callback is Callable and (callback as Callable).is_valid():
			(callback as Callable).call(result_of(done["status"], done["headers"], done["body"]))


## The Result for an HTTP answer.
static func result_of(status: int, headers: PackedStringArray, body: PackedByteArray) -> Result:
	var r := Result.new()
	r.status = status
	if status == 0:
		r.network = true
		r.error = "network"
		r.message = "NO ANSWER FROM THE SERVER"
		return r
	r.ok = status >= 200 and status < 300
	var text := body.get_string_from_utf8()
	if not text.strip_edges().is_empty():
		r.data = parse_json(text)
	var fields := r.dict()
	if not r.ok:
		r.error = str(fields.get("error", "http_%d" % status))
		r.message = str(fields.get("message", ""))
	r.retry_after_s = maxi(int(fields.get("retry_after_s", 0)), _retry_after(headers))
	return r


## JSON text to a Variant, or null if it is not JSON. Whole numbers come back as ints (or as text when too big for a double).
static func parse_json(text: String) -> Variant:
	var json := JSON.new()
	if json.parse(quote_big_numbers(text)) != OK:
		return null
	return normalise(json.data)


## Puts quotes around the integers of 16 digits or more that stand as values (outside strings), so the parser keeps them exactly.
static func quote_big_numbers(text: String) -> String:
	var out := PackedStringArray()
	var n := text.length()
	var i := 0
	var in_string := false
	var from := 0
	while i < n:
		var c := text.unicode_at(i)
		if in_string:
			if c == 92:
				i += 1
			elif c == 34:
				in_string = false
			i += 1
			continue
		if c == 34:
			in_string = true
			i += 1
		elif c == 45 or (c >= 48 and c <= 57):
			var j := i + 1
			var simple := true
			while j < n:
				var d := text.unicode_at(j)
				if d >= 48 and d <= 57:
					j += 1
				elif d == 46 or d == 101 or d == 69 or d == 43 or d == 45:
					simple = false
					j += 1
				else:
					break
			var digits := j - i - (1 if c == 45 else 0)
			if simple and digits >= 16:
				out.append(text.substr(from, i - from))
				out.append('"' + text.substr(i, j - i) + '"')
				from = j
			i = j
		else:
			i += 1
	if from == 0:
		return text
	out.append(text.substr(from))
	return "".join(out)


## Every float that is a whole number below 2^53 becomes an int, inside Arrays and Dictionaries too.
static func normalise(value: Variant) -> Variant:
	if value is float:
		var f: float = value
		if f == floorf(f) and absf(f) < MAX_SAFE:
			return int(f)
		return f
	if value is Array:
		var out: Array = []
		for item: Variant in value:
			out.append(normalise(item))
		return out
	if value is Dictionary:
		var out := {}
		for key: Variant in value:
			out[key] = normalise(value[key])
		return out
	return value


static func _retry_after(headers: PackedStringArray) -> int:
	for line in headers:
		if line.to_lower().begins_with("retry-after:"):
			var text := line.substr(12).strip_edges()
			if text.is_valid_int():
				return text.to_int()
	return 0
