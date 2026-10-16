extends "res://tests/test_case.gd"
## The fixed-step accumulator of scripts/app/fixed_step.gd: the five "advance (fixed timestep)" tests of the Phaser
## tests/loop.test.ts (tests/PARITY.md rows loop-1 to loop-5), plus the case the smoke test relies on: under
## --fixed-fps 60 every frame is exactly one step.

const FixedStep := preload("res://scripts/app/fixed_step.gd")

var clock: FixedStep


func before_each() -> void:
	clock = FixedStep.new()


func test_the_step_is_one_sixtieth_and_the_caps_are_phasers() -> void:
	assert_eq(FixedStep.STEP, 1.0 / 60.0)
	assert_eq(FixedStep.MAX_FRAME_SECONDS, 0.1)
	assert_eq(FixedStep.MAX_STEPS_PER_FRAME, 5)


## loop-1: "runs one step per 1/60 s of frame time".
func test_one_step_per_sixtieth_of_frame_time() -> void:
	assert_eq(clock.advance(FixedStep.STEP * 2.0 + 0.001), 2)
	assert_almost_eq(clock.accumulator, 0.001, 1e-9)


## loop-2: "a frame shorter than one step runs zero steps and carries the time over".
func test_a_short_frame_runs_no_step_and_carries_its_time() -> void:
	assert_eq(clock.advance(FixedStep.STEP / 2.0), 0)
	assert_almost_eq(clock.accumulator, FixedStep.STEP / 2.0, 1e-9)
	assert_eq(clock.advance(FixedStep.STEP / 2.0), 1, "two half frames make one step")


## loop-3: "a 240 Hz display still averages exactly one step per 1/60 s".
func test_240_hz_averages_one_step_per_sixtieth() -> void:
	var steps := 0
	for i in 240:
		steps += clock.advance(1.0 / 240.0)
	assert_eq(steps, 60)


## loop-4: "a huge frame (tab switch) is clamped and never runs more than the per-frame cap".
func test_a_huge_frame_is_clamped_to_the_cap() -> void:
	assert_eq(clock.advance(5.0), FixedStep.MAX_STEPS_PER_FRAME)
	assert_eq(clock.accumulator, 0.0, "the backlog is dropped, not replayed")
	assert_eq(clock.advance(FixedStep.STEP), 1, "the next frame runs normally")
	clock.reset()
	assert_eq(clock.advance(INF), FixedStep.MAX_STEPS_PER_FRAME, "an infinite frame counts as MAX_FRAME_SECONDS")
	assert_eq(clock.accumulator, 0.0)


## loop-5: "negative or NaN-like inputs do not run steps". In GDScript a NaN also leaves the accumulator a number.
func test_negative_or_nan_frames_run_no_steps() -> void:
	assert_eq(clock.advance(-1.0), 0)
	assert_eq(clock.accumulator, 0.0)
	assert_eq(clock.advance(NAN), 0)
	assert_false(is_nan(clock.accumulator))
	assert_eq(clock.advance(-INF), 0)
	assert_eq(clock.advance(FixedStep.STEP), 1, "the clock still works afterwards")


## Five steps' worth of time in one frame runs five steps and drops the remainder (Phaser's cap rule).
func test_a_frame_of_exactly_the_cap_drops_the_remainder() -> void:
	assert_eq(clock.advance(FixedStep.STEP * 5.5), 5)
	assert_eq(clock.accumulator, 0.0)


## --fixed-fps 60 hands _process() exactly 1/60 s, so the smoke test's frame N is the world's tick N.
func test_fixed_fps_60_is_one_step_every_frame() -> void:
	var off := 0
	for i in 3600:
		if clock.advance(1.0 / 60.0) != 1:
			off += 1
	assert_eq(off, 0, "frames that did not run exactly one step")
	assert_eq(clock.accumulator, 0.0)
