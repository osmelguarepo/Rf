import { SCORE, STAGE } from '../config';

/** Road distance (px) needed to clear a stage. Stage 1 = 12 000, then +4 000 per stage. */
export function stageGoal(stage: number): number {
  return STAGE.firstGoal + (stage - 1) * STAGE.goalStep;
}

/** Points for unused fuel at stage clear: 30 per whole unit. */
export function stageClearBonus(fuelAmount: number): number {
  return Math.floor(fuelAmount) * SCORE.stageClearPerFuel;
}
