extends RefCounted
## What the game asks of the web page (docs/SPEC_ONLINE.md §16.3, §16.4, §16.5), behind one small interface so no test needs a
## browser: this class is the real one (JavaScriptBridge, only in the browser export) and a test gives a subclass with the answers
## it wants. Off the web every call does nothing and available() is false.
##
## - The login redirect (navigate()) and the one-time code the page comes back with, in the URL fragment (fragment()), which
##   clean_url() then removes with history.replaceState so it is not left in the address bar or the history.
## - The page's origin (the API lives on the same origin, under /api).
## - Tab visibility (hidden()): a hidden tab stops running the game, so the game tells the server to hand its seat to a bot.

var web_override: int = -1
var _js_callback: JavaScriptObject = null
var _on_visibility: Callable = Callable()


func available() -> bool:
	if web_override >= 0:
		return web_override == 1
	return OS.has_feature("web")


func origin() -> String:
	return str(_eval("window.location.origin")) if available() else ""


## The part of the URL after "#", with the "#" ("" when there is none).
func fragment() -> String:
	return str(_eval("window.location.hash")) if available() else ""


## Removes the fragment (and any query) from the address bar without a reload.
func clean_url() -> void:
	if available():
		_eval("window.history.replaceState(null, '', window.location.pathname)")


## A full-page redirect.
func navigate(url: String) -> void:
	if available():
		_eval("window.location.assign(%s)" % JSON.stringify(url))


func hidden() -> bool:
	return available() and str(_eval("document.visibilityState")) == "hidden"


## Calls `on_change(hidden: bool)` whenever the tab is hidden or shown (the browser's visibilitychange event). A hidden tab stops
## the game loop, so this runs from the event itself: the game can send its message to the server before the tab goes quiet.
func watch_visibility(on_change: Callable) -> void:
	if not available():
		return
	_on_visibility = on_change
	_js_callback = JavaScriptBridge.create_callback(_visibility_event)
	var document: Variant = JavaScriptBridge.get_interface("document")
	document.addEventListener("visibilitychange", _js_callback)


## The fragment "#a=b&c=d" as {a: b, c: d} (values as they are; the one-time code is plain text).
static func parse_fragment(text: String) -> Dictionary:
	var out := {}
	var body := text.trim_prefix("#")
	if body.is_empty():
		return out
	for part in body.split("&", false):
		var at := part.find("=")
		if at > 0:
			out[part.substr(0, at)] = part.substr(at + 1).uri_decode()
	return out


func _visibility_event(_args: Array) -> void:
	if _on_visibility.is_valid():
		_on_visibility.call(hidden())


func _eval(code: String) -> Variant:
	return JavaScriptBridge.eval(code, true)
