extends RefCounted
## The answer of an API call (api_client.gd), the same whatever went wrong: a Result is handed to the call's callback, never an
## engine error. `ok` is a 2xx status. `status` is 0 when no answer came at all (`network`: the server could not be reached, the
## call timed out). `data` is the parsed JSON body (a Dictionary or an Array, or null when the body is empty or not JSON), with
## ids kept as text. `error` and `message` come from the API's {"error": code, "message": text} body, or are "network" and a
## short text when there was no answer. `retry_after_s` is the Retry-After header (or the body's retry_after_s), 0 if none.

const Self := preload("res://scripts/net/api_result.gd")

var ok: bool = false
var status: int = 0
var network: bool = false
var data: Variant = null
var error: String = ""
var message: String = ""
var retry_after_s: int = 0


## The body as a Dictionary ({} when it is not one).
func dict() -> Dictionary:
	if data is Dictionary:
		return data
	return {}


static func failure(p_error: String, p_message: String = "", p_status: int = 0) -> Self:
	var r := Self.new()
	r.error = p_error
	r.message = p_message
	r.status = p_status
	r.network = p_status == 0
	return r
