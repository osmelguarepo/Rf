extends RefCounted
## What the API client needs from HTTP (docs/SPEC_ONLINE.md §16.5), as small as Transport is for the WebSocket: send a request
## now, collect the finished ones on a later poll(). Implementations: HttpRequestTransport (HTTPRequest nodes, desktop and web)
## and the fakes of the tests, which answer from a table, so no test needs a network or the Go binary.

## Starts a request and returns its id. `method` is "GET", "POST" or "DELETE".
func request(_method: String, _url: String, _headers: PackedStringArray, _body: PackedByteArray) -> int:
	return -1


## The requests finished since the last call, oldest first: {"id": int, "status": int (0: no answer), "headers":
## PackedStringArray, "body": PackedByteArray}.
func poll() -> Array[Dictionary]:
	return []
