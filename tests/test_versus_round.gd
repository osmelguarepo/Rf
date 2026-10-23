extends "res://tests/test_case.gd"
## Versus rules, part 2 (docs/GODOT_PLAN.md §7 and §8 B1): eliminations, the end of a round, the round's winner,
## pause, a disconnected human seat, and when the world asks the bot hook for a byte. The match (best of three) and
## the round reset are match.gd's (B1b).

const Config := preload("res://scripts/sim/config.gd")
const Car := preload("res://scripts/sim/car.gd")
const Traffic := preload("res://scripts/sim/traffic.gd")
const World := preload("res://scripts/sim/world.gd")
const PlayerInput := preload("res://scripts/sim/player_input.gd")
const H := preload("res://tests/sim_helpers.gd")

const DT := Config.DT
const EPS := 1e-9
const BOT := PlayerInput.BOT

var std := Config.standard()


## A versus world whose bot hook records each call (the seat) and drives the seat with `bot_byte`.
class HookWorld extends "res://scripts/sim/world.gd":
	var calls: Array[int] = []
	var bot_byte: int = PlayerInput.NONE

	func _bot_byte(car: Car) -> int:
		calls.append(car.slot)
		return bot_byte


## A seat is out when it meets a truck or its tank is empty: alive 0 and EV_OUT in that step. A truck does nothing to
## an invulnerable seat, and puts it out the step its invulnerability ends.
func test_truck_and_empty_tank_eliminate() -> void:
	var w := H.quiet_versus(std, 2, 4, 0b0011)
	H.on_car(w, Config.KIND_TRUCK, 2)
	w.players[3].fuel = 0.001
	w.players[1].invulnerable = 30
	H.on_car(w, Config.KIND_TRUCK, 1)
	H.run(w, H.NONE)
	assert_eq(_alive(w), [1, 1, 0, 0], "bot 2 met a truck, bot 3 ran dry")
	assert_eq(_out(w), [false, false, true, true], "EV_OUT for the seats that went out")
	assert_eq(w.players[1].events, 0, "nothing at all for the invulnerable seat on the truck")
	assert_true((w.events & World.EV_OUT) != 0, "the world's events have it too")
	assert_eq(w.phase, World.RUNNING, "bots out: the round goes on")
	assert_gt(w.players[2].fuel, 99.0, "out by the truck, with fuel left")
	assert_eq(w.players[3].fuel, 0.0, "out by the empty tank")

	H.run(w, H.NONE, 28)
	assert_eq(w.players[1].alive, 1, "29 steps on the truck, still invulnerable")
	H.run(w, H.NONE)
	assert_eq(w.players[1].alive, 0, "the 30th: its invulnerability is over and the truck puts it out")
	assert_eq(w.phase, World.ROUND_OVER, "a human seat out ends the round")


## Every seat that goes out in a step goes out together, judged on that step's state: two humans (one meets a truck,
## one runs dry) and a bot all go out at once and the round ends; with no human left the winner is the best of the
## humans who went out in that step. Everything else in the step counts, such as a fuel car taken by the seat that
## also met a truck.
func test_simultaneous_eliminations() -> void:
	var w := H.quiet_versus(std, 6, 3, 0b011)
	H.on_car(w, Config.KIND_TRUCK, 0)
	w.players[1].fuel = 0.001
	w.players[2].fuel = 0.001
	w.players[0].score = 300
	w.players[1].score = 500
	w.players[2].score = 9000
	H.run(w, H.NONE)
	assert_eq(_alive(w), [0, 0, 0], "all three out in one step")
	assert_eq(_out(w), [true, true, true])
	assert_eq(w.phase, World.ROUND_OVER)
	assert_eq(w.winner, 1, "the best of the two humans out in this step; the bot does not count")

	var pickup := H.quiet_versus(std, 6, 3, 0b011)
	H.on_car(pickup, Config.KIND_TRUCK, 0)
	H.on_car(pickup, Config.KIND_FUEL_CAR, 0)
	pickup.players[1].fuel = 0.001
	pickup.players[0].score = 300
	pickup.players[1].score = 500
	H.run(pickup, H.NONE)
	assert_eq(_alive(pickup), [0, 0, 1])
	assert_eq(pickup.players[0].score, 1300, "seat 0 took the fuel car in the step a truck put it out")
	assert_eq(pickup.winner, 0, "and that wins it the round")


## A bot that goes out disappears and the round goes on: it is no longer moved, pushed by the bottom edge, collided
## with or followed by the camera, and the bot hook is not asked for its byte again. Only against a single human does
## the last bot out end the round, which the human then wins whatever the bots scored.
func test_bot_elimination_round_continues() -> void:
	var w := _hook_world(3, 3, 0b011)
	w.bot_byte = H.ACCEL
	var bot := w.players[2]
	bot.speed = 150.0
	var bytes: Array = [H.ACCEL, H.ACCEL, BOT]
	H.run_bytes(w, bytes, 30)
	assert_eq(w.camera_y, bot.y_world, "the bot leads")
	bot.fuel = 0.001
	H.run_bytes(w, bytes)
	assert_eq([bot.alive, w.phase], [0, World.RUNNING], "the bot is out, the round goes on")
	var calls := w.calls.size()
	var left := [bot.x, bot.y_world, bot.speed, bot.fuel]
	var camera := w.camera_y
	var standing := H.on_car(w, Config.KIND_YELLOW, 2)
	var bot_events := 0
	for tick in 400:
		H.run_bytes(w, bytes)
		bot_events |= bot.events
	assert_eq(w.calls.size(), calls, "no byte asked for the bot that is out")
	assert_eq([bot.x, bot.y_world, bot.speed, bot.fuel], left, "not moved")
	assert_gt(w.screen_y(bot.y_world) + bot.h, 400.0, "nor pushed: it is far below the bottom edge")
	assert_eq([bot_events, standing.struck_mask & 0b100], [0, 0], "nor collided with")
	assert_gt(w.camera_y, camera + 500.0, "the camera followed the humans past the spot")
	assert_eq(w.phase, World.RUNNING)

	var lone := H.quiet_versus(std, 4, 3, 0b001)
	lone.players[1].fuel = 0.001
	H.run(lone, H.NONE)
	assert_eq([lone.phase, lone.players[1].alive], [World.RUNNING, 0], "one bot out, one left: the round goes on")
	lone.players[2].fuel = 0.001
	lone.players[2].score = 5000
	H.run(lone, H.NONE)
	assert_eq(lone.phase, World.ROUND_OVER, "the last bot out against a single human ends the round at once")
	assert_true((lone.events & World.EV_ROUND_OVER) != 0)
	assert_eq([lone.winner, lone.players[0].alive], [0, 1], "the human wins, though the bot had more points")


## A human seat that goes out ends the round at the end of that step: the rest of the step still happens (another
## seat's pickup, a bot running dry), then the phase is ROUND_OVER with EV_ROUND_OVER and the winner set. After that
## the world takes no input and nothing moves.
func test_human_elimination_ends_round() -> void:
	var w := H.quiet_versus(std, 9, 3, 0b011)
	H.on_car(w, Config.KIND_TRUCK, 1)
	H.on_car(w, Config.KIND_FUEL_CAR, 0)
	w.players[2].fuel = 0.001
	w.players[0].speed = 100.0
	H.run(w, H.ACCEL)
	assert_eq(w.phase, World.ROUND_OVER)
	var expected := World.EV_ROUND_OVER | World.EV_OUT | World.EV_PICKUP
	assert_eq(w.events & expected, expected, "round over, a seat out and a pickup in the same step")
	assert_eq(_alive(w), [1, 0, 0], "the bot's empty tank in the same step counted")
	assert_eq(w.players[0].score, 1000, "seat 0's pickup in the same step counted")
	assert_eq(w.winner, 0, "the human still alive")

	var still := _without_clock(w)
	H.run(w, H.ACCEL_HIGH, 60)
	H.run(w, H.PAUSE)
	assert_eq(_without_clock(w), still, "nothing moved after the round ended")
	assert_eq([w.phase, w.events, w.tick], [World.ROUND_OVER, 0, 62])

	# A human seat that runs dry on its own ends the round the same way.
	var dry := H.quiet_versus(std, 9, 2, 0b11)
	dry.players[1].fuel = 0.001
	H.run(dry, H.ACCEL)
	assert_eq([dry.phase, dry.winner], [World.ROUND_OVER, 0])


## The winner: of the humans still alive (or, when none is, the humans who went out in the round's last step), the one
## with the most points, then the most distance, then the most fuel. Level on all three: nobody wins.
func test_winner_points_distance_fuel_then_none() -> void:
	# Seats 0 to 2 human, 3 a bot with the most points. Seat 0 runs dry; seats 1 and 2 are left.
	var by_points := _finish(4, 0b0111, [900, 400, 300, 5000], [0.0, 0.0, 0.0, 0.0], [0.001, 50.0, 50.0, 50.0])
	assert_eq(by_points.winner, 1, "more points; the human who went out cannot win while others are alive")
	var by_distance := _finish(4, 0b0111, [900, 400, 400, 0], [0.0, 10.0, 12.0, 0.0], [0.001, 50.0, 50.0, 50.0])
	assert_eq(by_distance.winner, 2, "level points: more distance")
	var by_fuel := _finish(4, 0b0111, [900, 400, 400, 0], [0.0, 12.0, 12.0, 0.0], [0.001, 60.0, 50.0, 50.0])
	assert_eq(by_fuel.winner, 1, "level points and distance: more fuel")
	var level := _finish(4, 0b0111, [900, 400, 400, 0], [0.0, 12.0, 12.0, 0.0], [0.001, 50.0, 50.0, 50.0])
	assert_eq(level.winner, World.NO_WINNER, "level on all three: nobody wins")
	assert_eq(level.phase, World.ROUND_OVER)

	# No human left: seats 0 and 1 meet trucks and seat 2 runs dry in the same step. The best of those three wins.
	var none_left := _finish(4, 0b0111, [700, 700, 300, 5000], [5.0, 9.0, 20.0, 0.0], [40.0, 40.0, 0.001, 50.0], [0, 1])
	assert_eq(_alive(none_left), [0, 0, 0, 1])
	assert_eq(none_left.winner, 1, "level points, more distance, among the humans out in the last step")
	var none_level := _finish(4, 0b0111, [700, 700, 300, 0], [9.0, 9.0, 0.0, 0.0], [40.0, 40.0, 0.001, 50.0], [0, 1])
	assert_eq(none_level.winner, World.NO_WINNER, "level on points, distance and fuel")


## With a single human seat, the human who goes out wins only by beating every bot still alive, on points and then
## distance: level with a bot (fuel does not count against bots) or behind one is no win. Bots already out, or out in
## the same step, do not count.
func test_single_human_needs_more_than_each_alive_bot() -> void:
	var ahead := _finish(4, 0b0001, [1000, 900, 999, 0], [0.0, 0.0, 0.0, 0.0], [0.001, 50.0, 50.0, 50.0])
	assert_eq([ahead.phase, ahead.winner], [World.ROUND_OVER, 0], "more points than each bot alive")
	var on_distance := _finish(4, 0b0001, [1000, 1000, 0, 0], [50.0, 40.0, 0.0, 0.0], [0.001, 50.0, 50.0, 50.0])
	assert_eq(on_distance.winner, 0, "level points with a bot, more distance")
	var behind := _finish(4, 0b0001, [1000, 1000, 0, 0], [50.0, 60.0, 0.0, 0.0], [0.001, 50.0, 50.0, 50.0])
	assert_eq(behind.winner, World.NO_WINNER, "a bot with as many points and more distance")
	var level := _finish(4, 0b0001, [1000, 1000, 0, 0], [50.0, 50.0, 0.0, 0.0], [80.0, 10.0, 50.0, 50.0], [0])
	assert_eq(level.winner, World.NO_WINNER, "level with a bot on points and distance, though with more fuel")
	var fewer := _finish(4, 0b0001, [1000, 1001, 0, 0], [90.0, 0.0, 0.0, 0.0], [0.001, 50.0, 50.0, 50.0])
	assert_eq(fewer.winner, World.NO_WINNER, "a bot with one point more")

	# A bot with more points that went out before does not count.
	var earlier := H.quiet_versus(std, 21, 4, 0b0001)
	earlier.players[0].score = 1000
	earlier.players[1].score = 3000
	earlier.players[1].fuel = 0.001
	H.run(earlier, H.NONE)
	assert_eq(earlier.phase, World.RUNNING)
	earlier.players[0].fuel = 0.001
	H.run(earlier, H.NONE)
	assert_eq([earlier.phase, earlier.winner], [World.ROUND_OVER, 0], "the bot out earlier does not count")
	# Nor does one that goes out in the same step as the human.
	var same_step := _finish(4, 0b0001, [1000, 3000, 10, 10], [0.0, 0.0, 0.0, 0.0], [0.001, 0.001, 50.0, 50.0])
	assert_eq(same_step.winner, 0, "the bot out in the same step is not alive after it")


## Bots never win a round, whatever they score: with two humans the surviving human wins over a bot with more points;
## with every human out and level, nobody wins, not the bot; a single human out with fewer points than a bot wins
## nothing, and neither does the bot. Over rounds with real traffic, every winner is a human seat.
func test_bots_never_win() -> void:
	var survivor := _finish(3, 0b011, [100, 200, 9999], [0.0, 0.0, 50.0], [0.001, 50.0, 50.0])
	assert_eq(survivor.winner, 1)
	var level := _finish(3, 0b011, [500, 500, 9999], [7.0, 7.0, 90.0], [40.0, 40.0, 50.0], [0, 1])
	assert_eq([level.winner, level.players[2].alive], [World.NO_WINNER, 1], "nobody, though the bot is alive")
	var lone := _finish(2, 0b01, [100, 9999], [0.0, 90.0], [0.001, 50.0])
	assert_eq(lone.winner, World.NO_WINNER, "nobody, not the bot")

	var ended := 0
	var won := 0
	var bad: Array = []
	for i in 12:
		var seats := 2 + i % 5
		var humans := 1 + (i * 37) % ((1 << seats) - 1)
		var w := World.versus(std, 500 + i, seats, humans)
		for tick in 6000:
			w.step(_drive(w, tick))
			if w.phase == World.ROUND_OVER:
				break
		if w.phase != World.ROUND_OVER:
			continue
		ended += 1
		if w.winner != World.NO_WINNER:
			won += 1
			if w.players[w.winner].human != 1:
				bad.append([i, w.winner])
	assert_eq(bad, [], "rounds a bot won")
	assert_gt(ended, 9, "rounds that ended")
	assert_gt(won, 3, "rounds with a winner")


## Any human seat's pause press pauses the round and any human seat's press resumes it. The bot byte and a bot
## seat's own byte never pause. While paused nothing moves and no bot is asked for a byte.
func test_any_human_pauses() -> void:
	var w := _hook_world(5, 3, 0b101)
	w.bot_byte = H.ACCEL
	H.run_bytes(w, [H.ACCEL, BOT, H.ACCEL])
	assert_eq([w.phase, w.calls.size()], [World.RUNNING, 1])
	H.run_bytes(w, [H.ACCEL, H.PAUSE, H.ACCEL])
	assert_eq(w.phase, World.RUNNING, "a bot seat's own byte with the pause bit does not pause")
	H.run_bytes(w, [H.ACCEL, BOT, H.PAUSE])
	assert_eq([w.phase, w.events], [World.PAUSED, World.EV_PAUSE], "human seat 2 paused")
	var calls := w.calls.size()
	var still := _without_clock(w)
	H.run_bytes(w, [H.ACCEL_HIGH, BOT, H.BRAKE], 90)
	assert_eq(_without_clock(w), still, "nothing moves while paused")
	assert_eq(w.calls.size(), calls, "no bot byte while paused, nor on the step that paused")
	H.run_bytes(w, [H.PAUSE, BOT, H.NONE])
	assert_eq([w.phase, w.events], [World.RUNNING, World.EV_RESUME], "human seat 0 resumed")
	assert_eq(w.calls.size(), calls, "nor on the step that resumed")
	H.run_bytes(w, [H.ACCEL, BOT, H.ACCEL])
	assert_eq(w.calls.size(), calls + 1, "running again")
	H.run_bytes(w, [BOT, BOT, H.ACCEL])
	assert_eq(w.phase, World.RUNNING, "0xFF never pauses, even on a human seat")


## A human seat that a bot drives after its controller went away (byte 0xFF) is still a human seat: the bot hook
## drives it, its byte never pauses, it can win the round, and its going out ends the round. When the controller is
## back, its bytes drive the car again.
func test_disconnect_seat_stays_human() -> void:
	var w := _hook_world(6, 3, 0b011)
	w.bot_byte = H.ACCEL
	var away := w.players[1]
	H.run_bytes(w, [H.NONE, BOT, BOT], 60)
	assert_eq(w.calls.size(), 120, "the hook drives seats 1 and 2")
	assert_almost_eq(away.speed, 70.0, 1e-9, "a second of the hook's throttle")
	assert_eq([away.human, w.phase], [1, World.RUNNING], "still human; 0xFF never paused")
	H.run_bytes(w, [H.NONE, H.BRAKE, BOT], 30)
	assert_eq(w.calls.size(), 150, "back: only seat 2 asks the hook")
	assert_almost_eq(away.speed, 10.0, 1e-9, "its own brake drives it again")
	w.players[0].fuel = 0.001
	H.run_bytes(w, [H.NONE, BOT, BOT])
	assert_eq([w.phase, w.winner], [World.ROUND_OVER, 1], "the bot-driven human seat wins: it is still human")

	var out := _hook_world(6, 3, 0b011)
	out.players[1].fuel = 0.001
	H.run_bytes(out, [H.NONE, BOT, BOT])
	assert_eq([out.phase, out.players[1].alive, out.winner], [World.ROUND_OVER, 0, 0], "its going out ends the round")


## The bot hook contract (for bot.gd, B1b): in versus mode the world asks _bot_byte() once per step for each live seat
## whose byte is 0xFF, in seat order, before anything moves, and only on steps that run: never while paused, on the
## steps that pause or resume, for a seat that is out, or after the round. (Single player, unchanged from A1, asks on
## every step, paused or not.)
func test_bot_hook_runs_once_per_bot_seat_on_running_steps() -> void:
	var w := _hook_world(7, 4, 0b1001)
	H.run_bytes(w, [H.ACCEL, BOT, BOT, BOT], 3)
	assert_eq(w.calls, [1, 2, 3, 1, 2, 3, 1, 2, 3] as Array[int], "bots 1, 2 and the disconnected human 3")
	w.calls.clear()
	H.run_bytes(w, [H.ACCEL, H.ACCEL, BOT, H.ACCEL])
	assert_eq(w.calls, [2] as Array[int], "a seat with a real byte is driven by it")
	w.calls.clear()
	H.run_bytes(w, [H.PAUSE, BOT, BOT, BOT])
	H.run_bytes(w, [H.ACCEL, BOT, BOT, BOT], 5)
	H.run_bytes(w, [H.PAUSE, BOT, BOT, BOT])
	assert_eq(w.calls.size(), 0, "pause, paused and resume steps")
	w.players[2].fuel = 0.001
	H.run_bytes(w, [H.ACCEL, BOT, BOT, BOT])
	assert_eq(w.calls, [1, 2, 3] as Array[int], "seat 2 still asked in the step it goes out")
	w.calls.clear()
	H.run_bytes(w, [H.ACCEL, BOT, BOT, BOT])
	assert_eq(w.calls, [1, 3] as Array[int], "not for a seat that is out")
	w.calls.clear()
	w.players[0].fuel = 0.001
	H.run_bytes(w, [H.ACCEL, BOT, BOT, BOT])
	assert_eq(w.phase, World.ROUND_OVER)
	w.calls.clear()
	H.run_bytes(w, [H.ACCEL, BOT, BOT, BOT], 10)
	assert_eq(w.calls.size(), 0, "nothing after the round")

	var single := HookWorld.new(std, 7, 2)
	H.run_bytes(single, [H.PAUSE, BOT])
	H.run_bytes(single, [H.NONE, BOT], 4)
	assert_eq([single.phase, single.calls.size()], [World.PAUSED, 5], "single player: every step")


# --- helpers ---------------------------------------------------------------------------------------------------------


## A quiet versus HookWorld.
func _hook_world(seed_value: int, seats: int, humans: int) -> HookWorld:
	var w := HookWorld.new(std, seed_value, seats, 0, World.MODE_VERSUS, humans)
	H.quiet(w)
	return w


## Ends a round in one step: each seat gets the score, distance and fuel given (fuel 0.001 runs dry in the step), and
## the seats in `trucks` meet a truck. Every car stands still, so the step changes only fuel (1/60 each) and who is out.
func _finish(seats: int, humans: int, scores: Array, distances: Array, fuels: Array, trucks: Array = []) -> World:
	var w := H.quiet_versus(std, 21, seats, humans)
	for p: Car in w.players:
		p.score = scores[p.slot]
		p.distance = distances[p.slot]
		p.fuel = fuels[p.slot]
	for seat: int in trucks:
		H.on_car(w, Config.KIND_TRUCK, seat)
	H.run(w, H.NONE)
	return w


static func _alive(w: World) -> Array:
	var out: Array = []
	for p: Car in w.players:
		out.append(p.alive)
	return out


static func _out(w: World) -> Array:
	var out: Array = []
	for p: Car in w.players:
		out.append((p.events & World.EV_OUT) != 0)
	return out


## The whole state but the step counter and the events of the last step.
static func _without_clock(w: World) -> Array:
	var a := w.to_array()
	a[3 + World.SCALARS.find("tick")] = 0
	a[3 + World.SCALARS.find("events")] = 0
	for seat: Array in a[4 + World.SCALARS.size()]:
		seat[12] = 0
	return a


## Bytes for a round with traffic: humans hold the throttle, take nitro from 160 km/h, steer into skids and change
## lane now and then; bots get 0xFF.
static func _drive(w: World, tick: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	for p: Car in w.players:
		if p.human == 0:
			bytes.append(BOT)
			continue
		var steer := int(signf(p.slide_vx))
		if steer == 0 and (tick + 40 * p.slot) % 240 < 20:
			steer = 1 if p.x < 300.0 else -1
		bytes.append(PlayerInput.encode(true, false, steer, p.speed >= 160.0))
	return bytes
