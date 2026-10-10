import type { GameInput } from './types';

/** The one-shot fields of GameInput. They are true only on the frame of the press. */
export type EdgeFields = Pick<GameInput, 'highGearPressed' | 'lowGearPressed' | 'pausePressed' | 'confirmPressed'>;

export const NO_EDGES: EdgeFields = {
  highGearPressed: false,
  lowGearPressed: false,
  pausePressed: false,
  confirmPressed: false,
};

/**
 * Keeps a press until a simulation step consumes it. A press that lands on a frame with zero
 * fixed steps (possible at high refresh rates) is therefore not lost.
 */
export function latchEdges(pending: EdgeFields, pressed: EdgeFields): EdgeFields {
  return {
    highGearPressed: pending.highGearPressed || pressed.highGearPressed,
    lowGearPressed: pending.lowGearPressed || pressed.lowGearPressed,
    pausePressed: pending.pausePressed || pressed.pausePressed,
    confirmPressed: pending.confirmPressed || pressed.confirmPressed,
  };
}
