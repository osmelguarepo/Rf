extends "res://scripts/net/http_transport.gd"
## The HttpTransport over HTTPRequest nodes. Each request is a node added under `host` (a node in the tree: the app); it is
## freed when it finishes. Works on desktop and in the browser (where it is the browser's fetch). The caller polls it every frame.

const Self := preload("res://scripts/net/http_request_transport.gd")

const TIMEOUT_S := 10.0
const METHODS := {
	"GET": HTTPClient.METHOD_GET, "POST": HTTPClient.METHOD_POST, "DELETE": HTTPClient.METHOD_DELETE,
	"PUT": HTTPClient.METHOD_PUT,
}

var host: Node = null
var _done: Array[Dictionary] = []
var _next_id: int = 1


func _init(p_host: Node = null) -> void:
	host = p_host


func request(method: String, url: String, headers: PackedStringArray, body: PackedByteArray) -> int:
	var id := _next_id
	_next_id += 1
	if host == null or not is_instance_valid(host) or not host.is_inside_tree() or not METHODS.has(method):
		_finish(id, 0, PackedStringArray(), PackedByteArray())
		return id
	var http := HTTPRequest.new()
	http.timeout = TIMEOUT_S
	host.add_child(http)
	http.request_completed.connect(_on_completed.bind(id, http))
	if http.request_raw(url, headers, METHODS[method], body) != OK:
		http.queue_free()
		_finish(id, 0, PackedStringArray(), PackedByteArray())
	return id


func poll() -> Array[Dictionary]:
	var out := _done
	_done = []
	return out


func _on_completed(result: int, code: int, headers: PackedStringArray, body: PackedByteArray, id: int, http: HTTPRequest) -> void:
	http.queue_free()
	_finish(id, code if result == HTTPRequest.RESULT_SUCCESS else 0, headers, body)


func _finish(id: int, status: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	_done.append({"id": id, "status": status, "headers": headers, "body": body})
