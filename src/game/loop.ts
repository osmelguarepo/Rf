import { SIM_STEP } from '../config';

/** Longest frame we will simulate in one go. Longer gaps (tab switch, debugger) are clamped. */
export const MAX_FRAME_SECONDS = 0.1;
/** Most fixed steps per rendered frame. Any backlog beyond this is dropped, not replayed. */
export const MAX_STEPS_PER_FRAME = 5;

export interface LoopAdvance {
  /** Number of fixed steps to run this frame. */
  steps: number;
  /** Leftover time to carry into the next frame. */
  accumulator: number;
}

/** Fixed-timestep accumulator. Deterministic for a given sequence of frame lengths. */
export function advance(accumulator: number, frameSeconds: number, step: number = SIM_STEP): LoopAdvance {
  let acc = accumulator + Math.min(Math.max(frameSeconds, 0), MAX_FRAME_SECONDS);
  let steps = 0;
  while (acc >= step && steps < MAX_STEPS_PER_FRAME) {
    acc -= step;
    steps += 1;
  }
  if (steps === MAX_STEPS_PER_FRAME) acc = 0;
  return { steps, accumulator: acc };
}
