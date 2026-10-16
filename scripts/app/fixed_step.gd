extends RefCounted
## The fixed-step accumulator (src/game/loop.ts in the Phaser version; docs/GODOT_PLAN.md §3 puts it in scripts/app).
##
## Each rendered frame adds its length; every whole 1/60 s in the accumulator is one World.step(). The leftover
## carries into the next frame, so any display rate averages exactly 60 steps a second. A frame longer than
## MAX_FRAME_SECONDS (a hitch, a debugger stop) counts as MAX_FRAME_SECONDS, and at most MAX_STEPS_PER_FRAME steps
## run per frame: a backlog beyond that is dropped, not replayed. Negative, NaN or infinite lengths never run
## extra steps. Under --fixed-fps 60 every frame is exactly one step.
##
## The arithmetic is Phaser's advance(), operation for operation, so the same frame lengths give the same steps.

const STEP := 1.0 / 60.0
const MAX_FRAME_SECONDS := 0.1
const MAX_STEPS_PER_FRAME := 5

## Time not yet stepped, in seconds.
var accumulator: float = 0.0


## Adds one frame's length and returns the number of fixed steps to run now.
func advance(frame_seconds: float) -> int:
	var frame := frame_seconds
	if is_nan(frame):
		frame = 0.0
	var acc := accumulator + minf(maxf(frame, 0.0), MAX_FRAME_SECONDS)
	var steps := 0
	while acc >= STEP and steps < MAX_STEPS_PER_FRAME:
		acc -= STEP
		steps += 1
	if steps == MAX_STEPS_PER_FRAME:
		acc = 0.0
	accumulator = acc
	return steps


func reset() -> void:
	accumulator = 0.0
