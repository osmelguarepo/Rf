extends RefCounted
## The names of the six seats (docs/SPEC_RANKING.md §8): what the leaderboard and the ranking lines call a player.
## A seat is P1 to P6 until its person edits the name on the join screen, arcade style, with the menu commands (so it
## works with a pad as well as the keyboard): up and down change the last letter, right adds a letter, left takes one
## away. A custom name has 3 to 8 letters or digits. Names last as long as the app (the session), like the ranking.

const PlayerColours := preload("res://scripts/view/player_colours.gd")

const CHARS := "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
const MIN_LENGTH := 3
const MAX_LENGTH := 8

## Per seat: the custom name, "" for none.
var _custom: Array[String] = ["", "", "", "", "", ""]


## A seat's name: the custom one, or P1 to P6.
func name_of(seat: int) -> String:
	if seat < 0 or seat >= _custom.size() or _custom[seat].is_empty():
		return PlayerColours.label(seat, true)
	return _custom[seat]


func is_custom(seat: int) -> bool:
	return seat >= 0 and seat < _custom.size() and not _custom[seat].is_empty()


## Up (-1) or down (+1): the last letter goes to the previous or next of CHARS, round the ends. A seat with its default
## name starts a custom one from it.
func cycle(seat: int, direction: int) -> void:
	if not _editable(seat):
		return
	_begin(seat)
	var text := _custom[seat]
	var at := CHARS.find(text[text.length() - 1])
	var next := posmod(at + direction, CHARS.length())
	_custom[seat] = text.substr(0, text.length() - 1) + CHARS[next]


## Right: adds a letter (A), up to MAX_LENGTH.
func extend(seat: int) -> void:
	if not _editable(seat):
		return
	_begin(seat)
	if _custom[seat].length() < MAX_LENGTH:
		_custom[seat] += CHARS[0]


## Left: takes the last letter away; a name at MIN_LENGTH goes back to the default.
func shorten(seat: int) -> void:
	if not _editable(seat) or not is_custom(seat):
		return
	if _custom[seat].length() <= MIN_LENGTH:
		_custom[seat] = ""
	else:
		_custom[seat] = _custom[seat].substr(0, _custom[seat].length() - 1)


func _editable(seat: int) -> bool:
	return seat >= 0 and seat < _custom.size()


## A seat's default name P1 is "P1" plus a letter once it is edited (3 letters), so every custom name has at least MIN_LENGTH.
func _begin(seat: int) -> void:
	if _custom[seat].is_empty():
		_custom[seat] = PlayerColours.label(seat, true) + CHARS[0]
