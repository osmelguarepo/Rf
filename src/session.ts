/**
 * Per-page-load state that survives scene changes and restarts. Lost on reload (no storage in the MVP).
 * Kept outside Phaser so the rules layer never needs it.
 */
export const session = {
  highScore: 0,
};
