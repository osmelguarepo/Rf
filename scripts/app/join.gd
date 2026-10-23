extends Node2D
## The join screen of the versus mode (B2; docs/DECISIONES_MULTIJUGADOR.md §2, docs/GODOT_PLAN.md §5): every pad that
## presses A appears on a seat with its colour, and any of them starts the race. The seats are the app's
## (scripts/input/seats.gd), so they outlive the screen: back here from a match, the same pads are still on their seats
## and the bots are still chosen. join_view.gd draws it over the still road.
##
## Each frame it takes the menu commands (scripts/input/nav.gd), in order:
## - A on a pad that holds no seat: the pad joins, on the lowest free seat (seats.gd join()).
## - On a pad that holds a seat: B leaves the seat; Start starts the race, when World.versus_valid() holds for the
##   seats (App.start_versus()); Back (Select) goes back to the title. The bots fill every empty seat by themselves.
## - The keyboard: Enter or Space seats it when nobody holds a seat (it is then the one person), and starts the race
##   once it holds one; Backspace gives its seat up; Esc goes back to the title. A pad that joins takes the keyboard's seat away.
## Presses that joined pads make here are dropped, so none reaches the race.

const App := preload("res://scripts/app/app.gd")
const Config := preload("res://scripts/sim/config.gd")
const Nav := preload("res://scripts/input/nav.gd")
const Seats := preload("res://scripts/input/seats.gd")
const Road := preload("res://scripts/view/road.gd")
const JoinView := preload("res://scripts/view/join_view.gd")

var app: App
var cfg: Config = Config.standard()
var seats: Seats
## Seconds since the screen opened.
var time: float = 0.0
var road: Road
var view: JoinView
## True once the screen has asked the app for another screen; the rest of that frame's commands are dropped.
var _leaving := false


## Builds the screen. The app calls it before adding the screen to the tree.
func setup(p_app: App) -> void:
	app = p_app
	seats = app.seats
	road = $Road
	view = $JoinView
	road.beside_panels = false
	road.setup(app.atlas, cfg)
	view.setup(app.atlas, cfg)
	view.show_seats(seats, time)


func frame(_steps: int, delta: float) -> void:
	time += delta
	for command: Vector2i in app.nav.take():
		if _leaving:
			return
		handle(command.x, command.y)
	if _leaving:
		return
	seats.clear_presses()
	view.show_seats(seats, time)


func on_focus_lost() -> void:
	pass


## One menu command from a device (Nav.KEYBOARD or a pad's).
func handle(device: int, command: int) -> void:
	if device == Nav.KEYBOARD:
		if command == Nav.BACK:
			_leave_to_title()
		elif command == Nav.ACCEPT:
			if seats.seat_of(Seats.KEYBOARD_DEVICE) >= 0:
				if seats.can_start():
					_leaving = true
					app.start_versus()
			else:
				seats.join_keyboard()
		elif command == Nav.SELECT:
			seats.leave(Seats.KEYBOARD_DEVICE)
		return
	if seats.seat_of(device) < 0:
		if command == Nav.ACCEPT:
			seats.join(device)
		return
	if command == Nav.BACK:
		seats.leave(device)
	elif command == Nav.START:
		if seats.can_start():
			_leaving = true
			app.start_versus()
	elif command == Nav.SELECT:
		_leave_to_title()


func _leave_to_title() -> void:
	_leaving = true
	app.show_title()
