/** One frame of player input, already mapped from keyboard or gamepad by src/input.ts. */
export interface GameInput {
  /** Accelerate (held). */
  accel: boolean;
  /** Brake (held). Overrides accel. */
  brake: boolean;
  /** -1 = left, 0 = none, 1 = right (held). */
  steer: -1 | 0 | 1;
  /** A button: select high gear (edge, pressed this frame). */
  highGearPressed: boolean;
  /** B button: select low gear (edge, pressed this frame). */
  lowGearPressed: boolean;
  /** Pause toggle (edge). */
  pausePressed: boolean;
  /** Confirm: start, retry, continue (edge). */
  confirmPressed: boolean;
}

export const NO_INPUT: GameInput = {
  accel: false,
  brake: false,
  steer: 0,
  highGearPressed: false,
  lowGearPressed: false,
  pausePressed: false,
  confirmPressed: false,
};

export type Gear = 'low' | 'high';
