# Hand-off between agents

Each agent of `docs/GODOT_PLAN.md` adds its section here (plan §1, "Entrega entre agentes"): the files it touched,
the verification commands with the last line each should print, the public API the next agents use, and the known
gaps. Editing a file another agent owns needs a test and a note in this file.

## A1: reference, golden traces, project base, simulation, runner and tests

### Files

- **Phaser project deleted.** It stays in git at commit `0a0841f` (local tag `phaser-reference`; the proxy refuses
  tag pushes). Read it with `git show 0a0841f:src/game/state.ts`.
- **Project base:** `project.godot`, `icon.svg`, `.gitignore`, `docs/.gdignore` (keeps `docs/screenshots/` out of the
  import, plan §6).
- **Assets:** `assets/` (moved from `public/assets/` with `git mv`), `assets/source/.gdignore`, `ASSETS.md`;
  `tools/slice-sheet.py` (moved from `scripts/`) and `tools/fetch_assets.py` (port of `scripts/fetch-assets.mjs`).
- **Simulation:** `scripts/sim/` `config.gd`, `rng.gd`, `car.gd`, `fuel.gd`, `traffic.gd`, `collision.gd`,
  `player_input.gd`, `world.gd`.
- **Golden traces:** `tools/gen_golden/` (vitest generator, its `README.md` and a `.gdignore`) and
  `tests/golden/phaser_golden.json`.
- **Tests:** `tests/run_tests.gd` (runner), `tests/test_case.gd` (base class and asserts), `tests/sim_helpers.gd`
  (helpers, not a test file), 15 test files `tests/test_*.gd` with 111 tests, `tests/PARITY.md`.
- **Entry point:** `tools/test.sh`.
- The `.uid` files Godot writes next to each script are meant to be committed.

### Verify

| Command | Last line | Exit |
|---|---|---|
| `GODOT=/tmp/claude-0/godot/Godot_v4.7.2-stable_linux.x86_64 tools/test.sh` | `111 passed, 0 failed` | 0 |
| The same after `rm -rf .godot` (fresh import, about 7 s) | `111 passed, 0 failed` | 0 |
| `tools/test.sh --only=test_golden` (one file; any substring of `tests/test_x.gd::test_y`, comma-separated) | `9 passed, 0 failed` | 0 |

`tools/test.sh` uses `${GODOT:-godot}`. It imports the project (and retries once if the import fails), runs
`tests/run_tests.gd` with a 600 s timeout, and fails on any `ERROR:` or `SCRIPT ERROR:` line in the import or the
test output. Exit codes: 0 all passed; 1 a test failed or none ran; 2 an error line with every test passing; 3 the
import failed twice; 70 the runner stopped before its end; 124 timeout; 127 Godot not found. The runner can also be
started directly: `godot --headless --path . -s res://tests/run_tests.gd -- --only=PATTERN`.

The runner was checked against a temporary file of deliberately broken tests (deleted afterwards). It printed one
`FAIL file::test` line with the file:line each for: a failed assert, an int compared with a float, a `push_error`,
a script error, a test without asserts, a file with a parse error (also caught by `test_all_scripts_compile`) and a
file that uses `await`. It exited with 1, 2 for an `ERROR:` line in a passing run, and 70 when the runner itself
aborted.

### Writing tests

- A test file is `tests/test_*.gd`. It starts with `extends "res://tests/test_case.gd"` and has no `class_name`. Test
  methods are named `test_*` and take no arguments. Files and methods run sorted by name, one instance per file.
  The optional hooks are `before_all`, `after_all`, `before_each` and `after_each`.
- Asserts use GUT's names, and each failure reports the file:line of the assert. `assert_eq` and `assert_ne` use
  strict types (`2 != 2.0`, also inside arrays and dictionaries). Also available: `assert_almost_eq`,
  `assert_true`/`assert_false` (bools only), `assert_gt`, `assert_lt`, `assert_between`, `assert_null`,
  `assert_not_null`, `assert_has`, `assert_does_not_have`, `fail_test` and `pass_test`. For bit-exact floats,
  `hex_of()` and `double_of()` read and write 16 hex digits.
- A test fails if an assert fails, if anything logs an error while it runs, or if it makes no assert. Tests are
  synchronous: a file that uses `await` fails as a whole. Never trigger an error on purpose (for example
  `World.from_array()` with the wrong profile calls `push_error`), because both the runner and `test.sh` fail on it.
- `tests/sim_helpers.gd` has `quiet_world()` (a world whose spawner never fires), `add_traffic()`, `on_car()`,
  `in_lane()`, `run()`, `car()` and `find()`.

### Public API of `scripts/sim`

Load every file with `const X := preload("res://scripts/sim/x.gd")`. The simulation has no `class_name`, no nodes, no
autoloads and no `static var` (`tests/test_sim_purity.gd` enforces plan §3). Every class is a `RefCounted` with
`clone()`.

**`config.gd` (Config).**
- `Config.standard()` is the game: 640×360, six 44 px lanes from x = 188 to 452, the player starting in lane 2
  (x = 291, centre 298) with its top on y = 292.
- `Config.phaser()` is Phaser's geometry, with K = 1, for the golden tests. `Config.for_profile(id)` picks either.
- Profile fields, every px value being Phaser × `k`: `view_width`, `view_height`, `lane_count`, `lane_width`,
  `road_left`, `road_right`, `anchor_single`, `start_lane`, `player_w`, `player_h`, `kind_w[kind]`, `kind_h[kind]`,
  `px_per_kmh`, `skid_speed`, `blue_reach`, and the gaps.
- Constants: `TICKS_PER_SECOND` (60), `DT`, `K`, `KIND_YELLOW`, `KIND_RED`, `KIND_BLUE`, `KIND_TRUCK`,
  `KIND_FUEL_CAR` (the rainbow car), `KIND_OIL`, `KIND_NAMES`, `FUEL_MAX`, `LOW_GEAR_TOP`, `HIGH_GEAR_TOP`,
  `INVULNERABLE_TICKS` (91) and the other tuning values.

**`world.gd` (World).** `World.new(cfg, seed, seats := 1, high_score := 0)` starts a game: stage 1, full tanks, an
empty road. `step(inputs: PackedByteArray)` advances one tick of 1/60 s, with one byte per seat.

| Field or method | Meaning |
|---|---|
| `phase` | `World.RUNNING`, `PAUSED`, `STAGE_CLEAR` or `GAME_OVER` (`PHASE_NAMES`). |
| `events` | Bits of the last step: `EV_SKID` 1, `EV_BUMP` 2, `EV_CRASH` 4, `EV_SPIN` 8, `EV_PICKUP` 16, `EV_PASS` 32, `EV_STAGE_CLEAR` 64, `EV_GAME_OVER` 128, `EV_PAUSE` 256, `EV_RESUME` 512 (`EVENT_NAMES`). Each car also has its own `events`. |
| `players` | `Array[Car]`, one per seat. `player()` is seat 0. |
| `traffic` | `Array[Traffic]`, in spawn order. |
| `screen_y(y_world)` | Screen y of a front (top) edge: `anchor + (camera_y - y_world)`. |
| `camera_y` | World y on the anchor line. It follows the leading live car and never moves back within a stage. It returns to 0 with every `y_world` when a new stage starts, so use it modulo the tile size for the road scroll. |
| `anchor` | 292 in single player. |
| `stage`, `goal` | Current stage and its goal in px (13 500, 15 750, 18 000 and 20 250, then the cycle repeats). |
| `stage_ticks`, `tick` | Running ticks this stage; all steps, in any phase. |
| `high_score`, `game_seed` | Pass `high_score` to the next `World.new`. Phaser restarted with seed + 1. |
| `to_array()`, `World.from_array(cfg, array)`, `checksum()`, `clone()` | Complete state, restore, SHA-256 and deep copy. |

**`car.gd` (Car), one per seat.**
- `x` is the hitbox's left edge on screen. `y_world` is the front edge, and in single player it is the distance
  driven this stage, so stage progress is `y_world / goal`.
- `w`, `h`: 14×24.
- `speed` in km/h; `gear` is `Car.GEAR_LOW` or `Car.GEAR_HIGH`.
- `slide_vx` is non-zero while skidding: negative slides left, positive right. `is_skidding()` tests it.
- `invulnerable`: ticks left, used for the blink.
- `fuel` (0–100), `score`, `alive`, `slot`, `events`.

**`traffic.gd` (Traffic).**
- `id`, `kind`, `x`, `y_world`, `w`, `h`, `kmh`.
- `target_lane` (−1 when not changing lane), `lanes_left`, `lane_timer` (ticks).
- `passed_mask`, `struck_mask` and `consumed_mask` have one bit per seat (`1 << slot`). `is_car()`.
- `Traffic.lane_x(cfg, lane, w)` and `Traffic.lane_of(cfg, x, w)`.

**`player_input.gd` (PlayerInput), the byte for one seat and one step.**

| Bit | Meaning |
|---|---|
| 0 | Accelerate. |
| 1 | Brake. |
| 2–3 | Steer + 1: 0 left, 1 none, 2 right. 3 reads as none. |
| 4 | High gear. |
| 5 | Pause press. |
| 6 | Confirm press. |
| `0xFF` | A bot drives the seat. |

- `NONE` (4) means no input. A zero byte steers left.
- `encode(accel, brake, steer, high_gear, pause, confirm)` builds a byte. `accel()`, `brake()`, `steer_of()`,
  `high_gear()`, `pause()`, `confirm()` and `is_bot()` read one.
- The input layer keeps pause and confirm presses with `latch(pending, pressed)` until a step consumes them, and
  merges them with the held bits through `with_edges(held, pending)`.
- A missing byte reads as no input. Pause and confirm count from any seat that is not a bot.

**`fuel.gd` (Fuel).** `Fuel.stage_clear_bonus(fuel)` is the bonus to show at stage clear. The score already
includes it.

**Notes for A2:**
- Sprites are 2× and 2 px wider than their hitbox (1 px on each side), so draw them at `x − 1`, `screen_y(y_world)`.
- The small yellow car's hitbox is 10×20, the truck's 18×40 and the oil's 18×12.
- The world does not pause by itself on focus loss. Send one `PAUSE` press while the phase is `RUNNING`.
- Retry after a game over by creating a new `World`.

### Ready for B1, not done

The data model is ready for phase B:
- N seats, each with its own input byte.
- Per-seat masks on traffic.
- `alive` per car.
- A camera on the leading live car.
- `game_seed`, for each bot's RNG.
- `mode` (only `MODE_STAGES` exists).
- `World._bot_byte(car)`, the hook where `bot.gd` goes. It is called inside `step()` for every `0xFF` seat, every
  tick, before the phase checks, so it must not draw from an RNG while paused.
- `FORMAT` and `SCALARS` in `to_array()`. A new field must be added to `SCALARS` (or to a `to_array()` of its own),
  or `test_to_array_covers_every_field` and `test_every_field_round_trips_and_moves_the_checksum` fail.

Not implemented:
- The versus mode and its anchor of 192.
- Start lanes (every seat starts in `start_lane`).
- The bottom edge.
- Distance points.
- Gaps that shrink every 1200 ticks.
- Eliminations, rounds and match.
- Bots: a `0xFF` seat gets no input for now.
- The rainbow-car tie rule: today the first seat in seat order that touches it gets it.
- The blue-car target: today it is the first live seat in seat order within reach, not the nearest one.

### Known gaps

- **Loop tests.** The 5 Phaser fixed-step accumulator tests (`loop.test.ts` advance) are marked dropped in
  `tests/PARITY.md`. The accumulator belongs to `scripts/app` (A2, plan §3). A2 should add its tests and point those
  rows at them.
- **View checks.** `test_frames_used_by_the_view_exist` and `test_view_scales_are_whole_numbers` in
  `tests/test_assets.gd` read `scripts/view/` and `scenes/` as text, so they check nothing until A2's code exists:
  - Frame names count when they are string literals that look like atlas names. The code-drawn names allowed are
    `truck` and `oil_puddle`; edit `CODE_DRAWN` there if the view draws others.
  - Scales count when they are constants or `Vector2` values with "scale" in the name.
- **Tolerances.** The golden world trace is bit-exact except each traffic object's screen y, compared within 1e-6 px
  (measured error 6.9e-10). The port keeps world y and derives the screen y from the camera. The six-lane
  no-traffic distance is within 1e-9 px of Phaser × K (measured 1.7e-10).
- **Lane timers.** Lane-change timers are `ceil(seconds × 60)` ticks. Phaser counted float seconds down, which can
  differ by one tick only when seconds × 60 lands within about 1e-13 of a whole number. The golden trace has no case.
- **Not exercised:** the 124 timeout path of `tools/test.sh`. Not verified here: Windows, and CI (A3).

### Deviations from the plan, with reasons

- **RNG method names.** The plan's `int(lo, hi)` is `Rng.int_range(lo, hi)`, because `int` is a GDScript type.
  `range` and `pick` are `float_range` and `pick_index`.
- **Import errors.** `tools/test.sh` also fails on `ERROR:` lines in the import output, not only in the test output,
  so a broken asset or script fails early. A failed first import is still retried, as the plan asks. B4: if
  GodotSteam prints errors on a successful import, narrow the check and add a note here.
- **`docs/.gdignore`.** Added so the screenshots in `docs/screenshots/` stay out of the imported project (plan §6).
- **`tests/sim_helpers.gd`.** Added, although plan §2 does not list it. It is shared test code; the runner only runs
  `test_*.gd`.
- **`World.game_seed`.** Added to the state, for B1's bot RNGs and for restarts.
- **Runner hooks.** One instance per file, with `before_all` and `after_all` as in GUT. The golden JSON (1.8 MB) is
  parsed once.
- **Values that follow Phaser's behaviour rather than its nominal numbers.** `INVULNERABLE_TICKS` is 91, because
  Phaser's 1.5 s lasted 91 steps in floating point. Yellow traffic uses the small-car hitbox (10×20) from the plan's
  sprite list.

## Lead notes after A1 (verified, committed)

The A1 adversarial verifier passed A1 (no blocker or major findings). The lead fixed two of its minor findings directly: the golden screen-y tolerance is now 1e-8, and the PARITY rows traffic-10 and loop-1 are corrected. The rest are hand-offs:

**For A2**
- Add the fixed-step accumulator tests in `scripts/app` (the Phaser `loop.ts` intents: one step per 1/60 s, carry-over, at most 5 steps per frame, large frames clamped) and update PARITY rows loop-1 to loop-5.
- `tests/test_assets.gd::test_frames_used_by_the_view_exist` and `test_view_scales_are_whole_numbers` pass vacuously today. Once `res://scripts/view` exists, they must assert that they checked at least one frame and one scale. Widen the scale pattern to cover `Vector2.ONE * n` and `Vector2(s, s)` with variables, and confirm in your HANDOFF section that the checks see your code.

**For A3**
- `README.md` still describes the deleted Phaser/npm project. Rewrite it for Godot (run, test, export, layout).

**For B1**
- Per-seat collision draws (oil skid direction, roadside crash fuel cost, centre-bump direction) come from the shared world RNG (`world.gd` around lines 185, 407 and 432). Adding a seat therefore shifts the traffic sequence: the verifier saw divergence in 5 of 10 seeds. In versus mode, draw these from per-seat streams seeded from `game_seed`, or use one shared draw per event per tick. In the stage mode, seat 0 must keep using the world RNG so the Phaser golden trace stays exact.
- `tests/test_seats.gd::test_two_players_same_inputs_identical` only holds in scenarios where no seat draws from the RNG. Rename it or narrow its stated property, and cover the general case after the fix above.
