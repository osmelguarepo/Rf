extends "res://scripts/net/web_bridge.gd"
## A WebBridge for the tests: a page that is there (or not) with a given URL fragment, recording the redirects and URL cleaning it is
## asked for; not a test file. `visibility_callback` is what watch_visibility() was given: call it to play a tab going away.

var page_origin: String = "https://play.example"
var page_fragment: String = ""
var navigated: Array[String] = []
var cleaned: int = 0
var is_hidden: bool = false
var visibility_callback: Callable = Callable()


func _init(on_web: bool = true) -> void:
	web_override = 1 if on_web else 0


func origin() -> String:
	return page_origin if available() else ""


func fragment() -> String:
	return page_fragment if available() else ""


func clean_url() -> void:
	cleaned += 1
	page_fragment = ""


func navigate(url: String) -> void:
	navigated.append(url)


func hidden() -> bool:
	return is_hidden


func watch_visibility(on_change: Callable) -> void:
	visibility_callback = on_change


## The tab goes hidden or comes back, as the browser's event would say.
func set_hidden(value: bool) -> void:
	is_hidden = value
	if visibility_callback.is_valid():
		visibility_callback.call(value)
