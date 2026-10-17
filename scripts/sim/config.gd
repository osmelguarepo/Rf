extends RefCounted
## Every tunable number of the simulation (docs/GODOT_PLAN.md §3-4 and §7, docs/PLAN.md §4).
##
## Constants that do not depend on the screen (km/h, fuel, points, durations) are `const`. Geometry and every
## magnitude in px or px/s lives in a profile, built by standard() (the game: 640x360, six lanes) or phaser() (the
## Phaser version's 360x640 three-lane road, kept for the golden tests). A profile multiplies each Phaser px value
## by K = 360/640 = 0.5625; the phaser profile uses K = 1, so its numbers are Phaser's own. The versus mode's px
## values (anchor_versus and the fields after it, the bots' bot_* included) are the game's own, not Phaser's (Phaser
## had no versus mode), and only the standard profile has them: World.versus() refuses the phaser profile.
##
## Pure: no class_name, no static var, no engine singletons. Fields are float and int only.

const Self := preload("res://scripts/sim/config.gd")

const PROFILE_STANDARD := 0
const PROFILE_PHASER := 1

## Fixed step: one World.step() is 1/60 s. Durations are whole ticks.
const TICKS_PER_SECOND := 60
const DT := 1.0 / 60.0

## K of the standard profile: 360 / 640.
const K := 0.5625

# --- Speed, in km/h. K does not change these (docs/PLAN.md §4).
const LOW_GEAR_TOP := 198.0
const HIGH_GEAR_TOP := 400.0
const LOW_GEAR_ACCEL := 70.0
## High gear is slow to start: below HIGH_GEAR_SLOW_BELOW it accelerates at HIGH_GEAR_SLOW_ACCEL.
const HIGH_GEAR_SLOW_BELOW := 160.0
const HIGH_GEAR_SLOW_ACCEL := 15.0
const HIGH_GEAR_ACCEL := 45.0
const BRAKE := 120.0
## Coasting with no throttle.
const DRAG := 25.0
## Speed above the current gear's top falls at this rate.
const OVERSPEED_FALL := 25.0
## Steering reaches its full rate at this speed: rate x min(1, speed / STEER_FULL_AT_KMH).
const STEER_FULL_AT_KMH := 30.0

# --- Crash and bump.
const CRASH_SPEED_FACTOR := 0.3
const CRASH_FUEL_MIN := 5
const CRASH_FUEL_MAX := 6
## Invulnerability after a roadside crash or a bump. Phaser set 1.5 s and counted it down in float seconds, where
## 1.5 - 90 x (1/60) leaves 3.3e-16, so it lasted 91 steps. The port keeps Phaser's 91.
const INVULNERABLE_TICKS := 91

# --- Fuel. 100 units is about 100 seconds of driving.
const FUEL_MAX := 100.0
const FUEL_DRAIN_PER_SEC := 1.0
const FUEL_PICKUP := 10.0
const FUEL_CAR_POINTS := 1000

# --- Score.
const POINTS_PER_PASSED_CAR := 50
const STAGE_CLEAR_POINTS_PER_FUEL := 30

# --- Stages, in Phaser px (a profile multiplies the goal by its K). 24 000, 28 000, 32 000, 36 000, then loop.
const STAGE_FIRST_GOAL := 24000.0
const STAGE_GOAL_STEP := 4000.0
const STAGE_GOAL_CYCLE := 4
## Each stage multiplies the spawn gaps by this. The running product is kept in World.gap_scale.
const SPAWN_GAP_SCALE := 0.9

# --- Traffic kinds. Codes are stored in the state, so do not renumber them.
const KIND_YELLOW := 0
const KIND_RED := 1
const KIND_BLUE := 2
const KIND_TRUCK := 3
const KIND_FUEL_CAR := 4
const KIND_OIL := 5
const KIND_COUNT := 6
const KIND_NAMES := ["yellow", "red", "blue", "truck", "fuel_car", "oil"]

## Own speeds in km/h, [min, max).
const YELLOW_SPEED_MIN := 80.0
const YELLOW_SPEED_MAX := 120.0
const RED_SPEED_MIN := 90.0
const RED_SPEED_MAX := 110.0
const BLUE_SPEED_MIN := 100.0
const BLUE_SPEED_MAX := 130.0
const TRUCK_SPEED := 60.0
const FUEL_CAR_SPEED := 90.0
## Lane changes: red once, blue 2 or 3 times.
const RED_LANE_CHANGES := 1
const BLUE_LANE_CHANGES_MIN := 2
const BLUE_LANE_CHANGES_MAX := 3
## Car type mix at spawn, in the order yellow, red, blue, truck. Weights need not sum to 1.
const CAR_KIND_ORDER := [KIND_YELLOW, KIND_RED, KIND_BLUE, KIND_TRUCK]
const CAR_KIND_WEIGHTS := [0.6, 0.2, 0.1, 0.1]
## Seconds before the first lane change, drawn at spawn, and between later ones. Stored as ticks.
const LANE_TIMER_FIRST_MIN := 1.0
const LANE_TIMER_FIRST_MAX := 2.5
const LANE_TIMER_NEXT_MIN := 1.5
const LANE_TIMER_NEXT_MAX := 3.0

## Gap kinds for Traffic.next_gap().
const GAP_CAR := 0
const GAP_OIL := 1
const GAP_FUEL := 2

# --- Phaser values in px or px/s, before a profile scales them (src/config.ts and src/game/traffic.ts).
const PHASER_STEER_BASE := 170.0
const PHASER_STEER_PER_KMH := 0.1
const PHASER_SKID_SPEED := 90.0
const PHASER_CORRECTION_ACCEL := 360.0
const PHASER_LANE_CHANGE_SPEED := 120.0
const PHASER_CAR_GAP := 350.0
const PHASER_CAR_GAP_JITTER := 0.0
const PHASER_CAR_GAP_MIN := 200.0
const PHASER_OIL_GAP := 4000.0
const PHASER_OIL_GAP_JITTER := 1000.0
const PHASER_FUEL_GAP := 8000.0
const PHASER_FUEL_GAP_JITTER := 2000.0
## The loose numbers in src/game/traffic.ts: spawn 4 px above the top, a lane is busy while a car's top is above
## y = 100, a car leaves 20 px below the screen or 120 px above it, blue cars react within 200 px.
const PHASER_SPAWN_ABOVE := 4.0
const PHASER_SPAWN_BUSY_Y := 100.0
const PHASER_OFF_BOTTOM := 20.0
const PHASER_OFF_TOP := 120.0
const PHASER_BLUE_REACH := 200.0

# --- Versus mode (World.MODE_VERSUS; docs/GODOT_PLAN.md §7, docs/DECISIONES_MULTIJUGADOR.md §2). "To tune": the
# plan's starting value, to adjust in play (DECISIONES §3). The px values are profile fields (anchor_versus...).
## Seats in a versus round, humans and bots together; at least one of them is human.
const VERSUS_SEATS_MIN := 2
const VERSUS_SEATS_MAX := 6
## Start lane of each seat (0 = leftmost lane of the six), by seat count: distinct lanes spread over the road, seat
## i in lane floor((i + 0.5) x 6 / seats), the middle of its share of the road. Seat 0 is on the left.
##   2 seats: 1 4    3 seats: 1 3 5    4 seats: 0 2 3 5    5 seats: 0 1 3 4 5    6 seats: 0 1 2 3 4 5
const VERSUS_START_LANES := [[], [], [1, 4], [1, 3, 5], [0, 2, 3, 5], [0, 1, 3, 4, 5], [0, 1, 2, 3, 4, 5]]
## Fuel per second a car loses while it touches the bottom edge, on top of FUEL_DRAIN_PER_SEC (to tune).
const EDGE_FUEL_DRAIN_PER_SEC := 2.0
## Distance points: this many for every whole distance_step px of world a car drives (to tune).
const VERSUS_DISTANCE_POINTS := 10
## Traffic gets denser: every VERSUS_SHRINK_TICKS running ticks (20 s) the car and oil gaps are multiplied by
## VERSUS_GAP_SHRINK, kept as a running product in World.gap_scale, down to versus_gap_min (to tune). Fuel-car gaps
## never shrink: with ever more fuel cars a player who takes them all would never run dry, and the round would not end.
const VERSUS_SHRINK_TICKS := 1200
const VERSUS_GAP_SHRINK := 0.9
## Seat RNG streams. mulberry32's state moves by 0x6D2B79F5 per draw, so every seed lies on one cycle of 2^32
## draws, and seed + n x 0x6D2B79F5 is the same stream n draws further on. Adding 2^28 x 0x6D2B79F5 mod 2^32 =
## 0x50000000 per slot (World.seat_seed()) puts the stream of slot s (s + 1) x 2^28 draws after the world's own, so
## the world stream and slots 0 to 14 never overlap within 268 435 456 draws.
const SEAT_SEED_STEP := 0x50000000

# --- Bots (scripts/sim/bot.gd; docs/GODOT_PLAN.md §7 "Bots"). The rules are the plan's: always accelerate, high
# gear from 160 km/h with 150 px free ahead, the clearest adjacent lane, steer into skids, chase fuel cars one lane
# away, react 12 ticks late. How a bot weighs the lanes is bot.gd's own; its px values are profile fields (bot_*),
# measured with tools/bot_stats.gd (docs/HANDOFF.md, B1 part 2).
## A bot takes high gear from this speed, while cfg.bot_free_ahead px ahead of it are free (plan §7).
const BOT_HIGH_GEAR_KMH := 160.0
## A bot's reaction time in ticks (plan §7: 12, 0.2 s): what it decides on one step drives its car 12 steps later.
const BOT_REACTION_TICKS := 12
## A bot's own RNG stream is World.seat_seed(game_seed, slot + BOT_STREAM_SLOT_OFFSET): slots 6 to 11, apart from the
## world's stream and the seats' own (World.seat_seed() keeps slots 0 to 14 2^28 draws apart).
const BOT_STREAM_SLOT_OFFSET := 6

# --- Match (scripts/sim/match.gd; docs/GODOT_PLAN.md §7 "Partida"): best of three rounds.
## Round wins that take the match.
const MATCH_WINS := 2
## With several humans and nobody at MATCH_WINS, the match ends after this many rounds: most wins, then most points,
## then most distance over the match (level on all three: nobody wins it).
const MATCH_ROUNDS_MAX := 5
## With a single human, rounds the human does not win (a bot ahead or level) that end the match.
const MATCH_LONE_LOSSES := 2
## Steps after a round ends before a confirm press counts (1 s). On a pad, A shifts gear and confirms, so presses made
## while racing must not skip the round's results (to tune).
const MATCH_CONFIRM_TICKS := 60

# --- Profile fields.
var profile: int = PROFILE_STANDARD
## Phaser px x k = this profile's px.
var k: float = 1.0
var view_width: float = 0.0
var view_height: float = 0.0
var lane_count: int = 0
var lane_width: float = 0.0
## Road surface between the barriers. A car may use x in [road_left, road_right - w].
var road_left: float = 0.0
var road_right: float = 0.0
## Screen y of the top edge of the car the camera follows, in single-player mode.
var anchor_single: float = 0.0
## Lane the single player starts in (0 = leftmost).
var start_lane: int = 0
## Hitboxes. The view draws sprites 1 px wider on each side in the standard profile.
var player_w: float = 0.0
var player_h: float = 0.0
var kind_w: Array[float] = []
var kind_h: Array[float] = []
## px of world per km/h per second: KMH_TO_PX (1) x k.
var px_per_kmh: float = 0.0
## Steering rate in px/s = (steer_base - steer_per_kmh x speed) x min(1, speed / STEER_FULL_AT_KMH).
var steer_base: float = 0.0
var steer_per_kmh: float = 0.0
## Skid: lateral slide speed (px/s) and how fast steering into the slide cancels it (px/s per second).
var skid_speed: float = 0.0
var correction_accel: float = 0.0
## Traffic lane-change speed, px/s.
var lane_change_speed: float = 0.0
## Spawn gaps in px of road scrolled, at stage 1. Car gaps never go below car_gap_min.
var car_gap: float = 0.0
var car_gap_jitter: float = 0.0
var car_gap_min: float = 0.0
var oil_gap: float = 0.0
var oil_gap_jitter: float = 0.0
var fuel_gap: float = 0.0
var fuel_gap_jitter: float = 0.0
var spawn_above: float = 0.0
var spawn_busy_y: float = 0.0
var off_bottom: float = 0.0
var off_top: float = 0.0
var blue_reach: float = 0.0
## Stage goals are Phaser px x goal_scale.
var goal_scale: float = 1.0
## 1: traffic changes lane only to an adjacent lane, and blue cars head for the player one lane at a time.
## 0: Phaser's rule, any other lane, and blue cars jump straight to the player's lane.
var adjacent_lanes: int = 0
## Versus mode, standard profile only (0 in the phaser profile, which has no versus mode). Screen y of the top edge
## of the leading car: 192 leaves 136 px behind it for the others (docs/GODOT_PLAN.md §3).
var anchor_versus: float = 0.0
## The bottom edge: a car's bottom edge never goes below screen y edge_bottom; a car held there, or whose bottom
## edge is at edge_touch or lower, touches it.
var edge_bottom: float = 0.0
var edge_touch: float = 0.0
## px of world per VERSUS_DISTANCE_POINTS (to tune).
var distance_step: float = 0.0
## The smallest car and oil gap the shrinking can reach.
var versus_gap_min: float = 0.0
## Bots (bot.gd), standard profile only, in the game's px. A bot keeps high gear only while this much road ahead of
## its car is free (plan §7: 150).
var bot_free_ahead: float = 0.0
## How far ahead of its car a bot weighs the lanes: a lane is as clear as the gap to its first obstacle, at most this.
var bot_look_ahead: float = 0.0
## A truck counts this much nearer than it is when a bot weighs a lane (trucks put a car out; other cars only bump).
var bot_truck_caution: float = 0.0
## Another player's car just ahead of a bot counts this much further than it is (the bot gives way to it).
var bot_player_ease: float = 0.0
## A bot heads for a neighbouring lane only when it is this much clearer than the lane it is heading for.
var bot_lane_margin: float = 0.0
## A bot chases a fuel car up to this far ahead (in its lane or the next one).
var bot_fuel_reach: float = 0.0
## A lane's corridor is a car's width centred in the lane, plus this much on each side.
var bot_side_margin: float = 0.0


## The game: 640x360, six lanes of 44 px from x = 188 to 452, sprites drawn at 2x (docs/GODOT_PLAN.md §4).
static func standard() -> Self:
	var c := Self.new()
	c.profile = PROFILE_STANDARD
	c.k = K
	c.view_width = 640.0
	c.view_height = 360.0
	c.lane_count = 6
	c.lane_width = 44.0
	c.road_left = 188.0
	c.road_right = 452.0
	# 520 x K = 292.5, rounded down to a whole pixel.
	c.anchor_single = 292.0
	c.start_lane = 2
	# Sprites at 2x: cars 16x24, small car 12x20, truck 20x40, oil 20x12. Hitboxes are 1 px narrower on each side.
	c.player_w = 14.0
	c.player_h = 24.0
	c.kind_w = [10.0, 14.0, 14.0, 18.0, 14.0, 18.0]
	c.kind_h = [20.0, 24.0, 24.0, 40.0, 24.0, 12.0]
	# Six lanes share the traffic that three lanes had, so car and oil gaps are halved (x 3/6) to keep Phaser's
	# density per lane. Fuel cars keep their gap per road (x K only).
	_scale(c, K, 3.0 / 6.0)
	c.adjacent_lanes = 1
	# Versus mode (docs/GODOT_PLAN.md §3, §7): the leader's top at y = 192; a car's bottom edge at most at 352 (8 px
	# above the screen's bottom), touching from 351.5; 10 points per 100 px of world (to tune); car and oil gaps
	# shrink to 40 px at least, which the car gap reaches after 9 shrinks (180 s).
	c.anchor_versus = 192.0
	c.edge_bottom = 352.0
	c.edge_touch = 351.5
	c.distance_step = 100.0
	c.versus_gap_min = 40.0
	# Bots (bot.gd): 150 px free for high gear (plan §7). The rest are bot.gd's choices, measured with
	# tools/bot_stats.gd: a lane is weighed 168 px ahead (about 0.9 s at the top closing speed, 400 km/h on a 60 km/h
	# truck); a truck counts 168 px nearer, so any truck in that reach ranks a lane below every lane without one (with
	# 48, bots took a truck's lane over a car alongside and died for it); another player's car just ahead counts 96 px
	# further than it is; a lane must be 24 px clearer to change to it; fuel cars are chased 160 px ahead; 2 px of side
	# margin.
	c.bot_free_ahead = 150.0
	c.bot_look_ahead = 168.0
	c.bot_truck_caution = 168.0
	c.bot_player_ease = 96.0
	c.bot_lane_margin = 24.0
	c.bot_fuel_reach = 160.0
	c.bot_side_margin = 2.0
	return c


## The Phaser version's geometry and numbers (K = 1): 360x640, three lanes of 80 px from x = 60 to 300.
static func phaser() -> Self:
	var c := Self.new()
	c.profile = PROFILE_PHASER
	c.k = 1.0
	c.view_width = 360.0
	c.view_height = 640.0
	c.lane_count = 3
	c.lane_width = 80.0
	c.road_left = 60.0
	c.road_right = 300.0
	c.anchor_single = 520.0
	c.start_lane = 1
	c.player_w = 26.0
	c.player_h = 44.0
	c.kind_w = [24.0, 24.0, 24.0, 30.0, 24.0, 40.0]
	c.kind_h = [40.0, 40.0, 40.0, 60.0, 40.0, 24.0]
	_scale(c, 1.0, 1.0)
	c.adjacent_lanes = 0
	return c


static func for_profile(p_profile: int) -> Self:
	return phaser() if p_profile == PROFILE_PHASER else standard()


## Every px and px/s value is Phaser's value x k. Car and oil gaps are also x density (fewer lanes, more cars).
static func _scale(c: Self, p_k: float, density: float) -> void:
	c.px_per_kmh = 1.0 * p_k  # Phaser KMH_TO_PX = 1
	c.steer_base = PHASER_STEER_BASE * p_k  # 170 x K = 95.625
	c.steer_per_kmh = PHASER_STEER_PER_KMH * p_k  # 0.1 x K = 0.05625
	c.skid_speed = PHASER_SKID_SPEED * p_k  # 90 x K = 50.625
	c.correction_accel = PHASER_CORRECTION_ACCEL * p_k  # 360 x K = 202.5
	c.lane_change_speed = PHASER_LANE_CHANGE_SPEED * p_k  # 120 x K = 67.5
	c.car_gap = PHASER_CAR_GAP * p_k * density  # 350 x K x 3/6 = 98.4375
	c.car_gap_jitter = PHASER_CAR_GAP_JITTER * p_k * density  # 0
	c.car_gap_min = PHASER_CAR_GAP_MIN * p_k * density  # 200 x K x 3/6 = 56.25
	c.oil_gap = PHASER_OIL_GAP * p_k * density  # 4000 x K x 3/6 = 1125
	c.oil_gap_jitter = PHASER_OIL_GAP_JITTER * p_k * density  # 1000 x K x 3/6 = 281.25
	c.fuel_gap = PHASER_FUEL_GAP * p_k  # 8000 x K = 4500
	c.fuel_gap_jitter = PHASER_FUEL_GAP_JITTER * p_k  # 2000 x K = 1125
	c.spawn_above = PHASER_SPAWN_ABOVE * p_k  # 4 x K = 2.25
	c.spawn_busy_y = PHASER_SPAWN_BUSY_Y * p_k  # 100 x K = 56.25
	c.off_bottom = PHASER_OFF_BOTTOM * p_k  # 20 x K = 11.25
	c.off_top = PHASER_OFF_TOP * p_k  # 120 x K = 67.5
	c.blue_reach = PHASER_BLUE_REACH * p_k  # 200 x K = 112.5
	c.goal_scale = p_k  # 24 000 x K = 13 500


## Goal of a stage in this profile's px: 24 000, 28 000, 32 000, 36 000, then back to 24 000 (x k).
func stage_goal(stage: int) -> float:
	var phaser_goal := STAGE_FIRST_GOAL + STAGE_GOAL_STEP * float((stage - 1) % STAGE_GOAL_CYCLE)
	return phaser_goal * goal_scale


func clone() -> Self:
	var c := Self.new()
	c.profile = profile
	c.k = k
	c.view_width = view_width
	c.view_height = view_height
	c.lane_count = lane_count
	c.lane_width = lane_width
	c.road_left = road_left
	c.road_right = road_right
	c.anchor_single = anchor_single
	c.start_lane = start_lane
	c.player_w = player_w
	c.player_h = player_h
	c.kind_w = kind_w.duplicate()
	c.kind_h = kind_h.duplicate()
	c.px_per_kmh = px_per_kmh
	c.steer_base = steer_base
	c.steer_per_kmh = steer_per_kmh
	c.skid_speed = skid_speed
	c.correction_accel = correction_accel
	c.lane_change_speed = lane_change_speed
	c.car_gap = car_gap
	c.car_gap_jitter = car_gap_jitter
	c.car_gap_min = car_gap_min
	c.oil_gap = oil_gap
	c.oil_gap_jitter = oil_gap_jitter
	c.fuel_gap = fuel_gap
	c.fuel_gap_jitter = fuel_gap_jitter
	c.spawn_above = spawn_above
	c.spawn_busy_y = spawn_busy_y
	c.off_bottom = off_bottom
	c.off_top = off_top
	c.blue_reach = blue_reach
	c.goal_scale = goal_scale
	c.adjacent_lanes = adjacent_lanes
	c.anchor_versus = anchor_versus
	c.edge_bottom = edge_bottom
	c.edge_touch = edge_touch
	c.distance_step = distance_step
	c.versus_gap_min = versus_gap_min
	c.bot_free_ahead = bot_free_ahead
	c.bot_look_ahead = bot_look_ahead
	c.bot_truck_caution = bot_truck_caution
	c.bot_player_ease = bot_player_ease
	c.bot_lane_margin = bot_lane_margin
	c.bot_fuel_reach = bot_fuel_reach
	c.bot_side_margin = bot_side_margin
	return c
