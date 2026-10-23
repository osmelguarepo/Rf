extends RefCounted
## Túnel de los Gemelos (docs/IDEAS_POWERUPS.md, idea 1): tunnel mouths stand on the road, and when the leading car
## (the camera) crosses one, every player car looks the same for TWIN_TICKS. Only the look changes: the simulation,
## its checksum and the goldens do not know about tunnels, so nothing about the race moves.
##
## Where. Mouth k stands at entrance(game_seed, k): a function of the seed alone, in world px, one every SPACING plus
## a jitter. No RNG stream is touched.
## When. A Tunnel instance watches the world frame by frame (update()) and notes the stage tick at which the camera
## first passed a mouth. It counts world ticks, so it freezes with a pause and is the same at any frame rate. A new
## round or game (the seed changes, or the tick count goes back) starts it afresh.

const Config := preload("res://scripts/sim/config.gd")
const World := preload("res://scripts/sim/world.gd")

## How long the cars look alike: 4 s.
const TWIN_TICKS := 4 * Config.TICKS_PER_SECOND
## World px from the start to the first mouth, between two mouths, and the most a mouth is moved from its slot.
const FIRST := 3000.0
const SPACING := 4500.0
const JITTER := 1500.0
## The mouth's lintel: its height on screen (px), and the width of each post.
const LINTEL_H := 8
const POST_W := 6
## How dark the road is inside the tunnel, 0 to 1.
const DARKNESS := 0.4

var _seed: int = -1
var _last_ticks: int = 0
var _next: int = 0
var _started: int = -1


## Where mouth k stands, in world px.
static func entrance(game_seed: int, k: int) -> float:
	var h := (game_seed + (k + 1) * 0x9E3779B1) & 0xFFFFFFFF
	h = ((h ^ (h >> 16)) * 0x45D9F3B) & 0xFFFFFFFF
	h = ((h ^ (h >> 16)) * 0x45D9F3B) & 0xFFFFFFFF
	h = h ^ (h >> 16)
	return FIRST + k * SPACING + JITTER * (float(h) / 4294967296.0)


## Indices of the mouths whose world y is in [low, high].
static func visible(game_seed: int, low: float, high: float) -> Array[int]:
	var out: Array[int] = []
	var k := maxi(0, floori((low - FIRST - JITTER) / SPACING))
	while true:
		var y := entrance(game_seed, k)
		if y > high and k * SPACING + FIRST > high:
			break
		if y >= low and y <= high:
			out.append(k)
		k += 1
	return out


## Watches the world after a render: starts the twin look when the camera has passed a mouth.
func update(w: World) -> void:
	if w.game_seed != _seed or w.stage_ticks < _last_ticks:
		_seed = w.game_seed
		_next = 0
		_started = -1
		while entrance(_seed, _next) <= w.camera_y:
			_next += 1
	_last_ticks = w.stage_ticks
	var crossed := false
	while entrance(_seed, _next) <= w.camera_y:
		_next += 1
		crossed = true
	if crossed:
		_started = w.stage_ticks


## True while the cars look alike.
func active(w: World) -> bool:
	return _started >= 0 and w.stage_ticks - _started < TWIN_TICKS
