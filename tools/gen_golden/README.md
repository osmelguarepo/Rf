# Golden traces from the Phaser rules

`phaser_golden.test.ts` runs the TypeScript rules of the Phaser version (`src/game` at commit **`0a0841f`**, local tag
`phaser-reference`) and writes `tests/golden/phaser_golden.json`. The Godot tests in `tests/test_golden.gd` replay
the same inputs through `scripts/sim` and compare the results. The Phaser project is deleted from the working tree,
so this folder only runs inside a checkout of that commit. Godot skips the folder (`.gdignore`).

## What the file holds

| Section | Content | Compared in Godot |
|---|---|---|
| `rng` | First 64 outputs (u32) of 10 seeds; a digest of 1 000 000 outputs of seed 20261014 (xor, sum mod 2^32, FNV hash, every 100 000th output); `int`, `range` and `pick` results of seed 99 | Exact |
| `speed_trace` | 2000 calls of `stepSpeed` from 0 km/h with scripted inputs that reach every branch (both gears, high gear below and above 160 km/h, coasting, overspeed fall, brake) | Bit-exact |
| `no_traffic_60s` | `createGame(1)` with the spawner switched off, 3600 steps of throttle, high gear, coasting, braking and one pause; speed, fuel and distance after each step | Speed and fuel bit-exact; distance × K within 1e-9 (6-lane profile) |
| `world_phaser` | 3 minutes (10 800 steps) of the whole game, seed 20261014; per step: input byte, phase, stage, x, speed, fuel, distance, score, events, traffic count, next id, a hash of the exact traffic state, the sum of traffic screen y, a hash of the remaining player state; a full snapshot every 60 steps | `world.gd` with the `phaser` profile: exact, except traffic screen y (the port keeps world y, so the screen y is rebuilt from the camera) |

Encoding:
- Doubles are the 8 bytes of the IEEE-754 value, little-endian, as 16 hex digits. Never decimal text.
- RNG outputs are the u32 behind `next()` (`next() × 2^32`, exact).
- Inputs are the Godot input byte from `scripts/sim/player_input.gd`: bit 0 accelerate, bit 1 brake, bits 2–3 steer + 1,
  bit 4 high gear, bit 5 pause, bit 6 confirm.
- Phaser counts invulnerability and lane-change timers down in float seconds. The file gives the number of 1/60 s
  steps Phaser still needs to reach zero, which is what the port stores. One consequence: Phaser's 1.5 s of
  invulnerability lasts **91** steps, because 1.5 − 90 × (1/60) leaves 3.3e-16 in floating point.
- Hashes are FNV-1a over u32 words: `h = 2166136261`, then `h = ((h ^ word) × 16777619) mod 2^32` per word; a double
  is its two little-endian words. The code and phase lists are in the file (`codes`).

The world inputs come from a small autopilot in the generator (avoid trucks, chase fuel cars, steer into skids) plus
scripted segments: pause at step 600 and resume at 660, brake 1500–1619, no skid correction 1540–1699, steer into
the left barrier 3000–3069, coast 3600–3719, and drive into trucks from 9400 until the first game over. A game over
is followed 60 steps later by `createGame(seed + 1, highScore)`, as GameScene does on Enter; `restarts` lists when.
The recorded bytes are what Godot replays, so the autopilot never needs porting. The test fails if the trace stops
covering passes, bumps, oil, pickups, a roadside crash, a stage clear, a game over, and pause/resume.

## Regenerating

Needs Node 22.12 or later and network access for `npm ci`. From the repository root:

```bash
git worktree add /tmp/phaser-ref 0a0841f
cp -r tools/gen_golden /tmp/phaser-ref/tools/
(cd /tmp/phaser-ref && npm ci && \
  GOLDEN_OUT="$OLDPWD/tests/golden/phaser_golden.json" npx vitest run --config tools/gen_golden/vitest.config.ts)
git worktree remove --force /tmp/phaser-ref
```

`GOLDEN_OUT` sets the output path; without it the file goes to `tests/golden/` inside the worktree. The output is
deterministic: running it twice gives the same bytes. After a change to the generator, run `tools/test.sh` and
check that `tests/test_golden.gd` still passes.
