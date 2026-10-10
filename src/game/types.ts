/** One frame of player input, already mapped from keyboard or gamepad by src/input.ts. */
export interface GameInput {
  /** Throttle (held): Up/W, B (Z) or A (X). A also selects high gear. */
  accel: boolean;
  /** Brake (held): Down/S. Overrides the throttle. */
  brake: boolean;
  /** -1 = left, 0 = none, 1 = right (held). */
  steer: -1 | 0 | 1;
  /** High gear (held): A (X). Higher top speed, but slow to start from a standstill. */
  highGear: boolean;
  /** Pause toggle (edge, true only on the frame of the press). */
  pausePressed: boolean;
  /** Confirm: start, retry, continue (edge). */
  confirmPressed: boolean;
}

export const NO_INPUT: GameInput = {
  accel: false,
  brake: false,
  steer: 0,
  highGear: false,
  pausePressed: false,
  confirmPressed: false,
};

export type Gear = 'low' | 'high';
