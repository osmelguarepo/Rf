import { SCORE, STAGE } from '../config';

/**
 * Road distance (px) needed to clear a stage: 24 000, 28 000, 32 000, 36 000, then the goal loops
 * back to 24 000 (see docs/PLAN.md §11). Difficulty keeps rising through the spawn gaps.
 */
export function stageGoal(stage: number): number {
  return STAGE.firstGoal + STAGE.goalStep * ((stage - 1) % STAGE.goalCycle);
}

/** Points for unused fuel at stage clear: 30 per whole unit. */
export function stageClearBonus(fuelAmount: number): number {
  return Math.floor(fuelAmount) * SCORE.stageClearPerFuel;
}
