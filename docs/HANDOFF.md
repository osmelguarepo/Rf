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
| `high_score`, `game_seed` | Pass `high_score` to the next `World.new`. (Phaser drew a random seed per game; the Godot app uses the previous seed + 1, see A2.) |
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

## A2: scenes, view, input, app, smoke test and screenshots

### Files

- **App** (`scripts/app/`): `app.gd` (root of the main scene: boot, window fit, input routing, fixed step, focus
  pause, screen switching, session, `--selftest`), `fixed_step.gd` (the accumulator), `title.gd` and `game.gd` (the two
  screens' controllers).
- **Input** (`scripts/input/`): `keyboard.gd` (the input map, built in code), `pads.gd` (joypads, read per device),
  `held.gd` (held-control bits and the byte they make), `local_input.gd` (single player: keyboard plus every pad, with
  latched presses).
- **View** (`scripts/view/`): `view_config.gd` (files, frame names, scales, colours, text sizes, layout), `atlas.gd`
  (atlas, AtlasTextures, code-drawn frames, font), `pixel_art.gd` (the truck and oil-puddle grids of
  `src/render/pixelArt.ts`), `draw.gd` (text, boxes, gauges, sprites on hitboxes), `road.gd`, `cars.gd`, `hud.gd`,
  `title_view.gd`.
- **Scenes** (`scenes/`): `boot.tscn` (the main scene: an `App` node), `title.tscn` (`Title`: `Road`, `TitleView`),
  `game.tscn` (`Game`: `Road`, `Cars`, `Hud`).
- **Tools**: `tools/smoke.gd`, `tools/screenshots.gd`, `tools/scalecheck.gd`, and `tools/tool_base.gd`, which they
  extend (boots the game under the tool's SceneTree, sends key and joypad events, counts logged errors, an autopilot
  that steers with the arrow keys). `tools/run_tool.sh` runs the three with the error filter of `tools/test.sh`.
- **Tests** (62 new, 173 in all): `tests/test_fixed_step.gd` (8), `tests/test_input_devices.gd` (15),
  `tests/test_view.gd` (18), `tests/test_app.gd` (20), and one more in `tests/test_assets.gd`.
- **Screenshots**: `docs/screenshots/01-title.png` to `06-skid-low-fuel.png` (below).
- **Files of other agents that A2 edited**, each with a test:
  - `project.godot`: `application/run/main_scene="res://scenes/boot.tscn"`, which the game needs to start
    (`tests/test_app.gd::test_the_main_scene_is_the_boot_scene_with_the_app`).
  - `tests/test_assets.gd`: the two view checks, as the lead asked (see "The view checks see the view" below;
    `test_scale_check_reads_numbers_constants_and_vectors` tests the new scale reader).
  - `tests/PARITY.md`: rows loop-1 to loop-5 now point at `tests/test_fixed_step.gd`, and the "Not ported" note says
    the view checks have something to check (`tests/test_parity.gd` checks every reference).

### Verify

| Command | Last line | Exit |
|---|---|---|
| `GODOT=/tmp/claude-0/godot/Godot_v4.7.2-stable_linux.x86_64 tools/test.sh` | `173 passed, 0 failed` | 0 |
| The same after `rm -rf .godot` | `173 passed, 0 failed` | 0 |
| `tools/run_tool.sh smoke` (about 18 s: the import, then the plan's smoke command, which takes about 14 s) | `smoke: PASS` | 0 |
| `$GODOT --headless --path . -- --selftest` | `selftest: ok (600 ticks checked, 120 frames drawn)` | 0 |
| `tools/run_tool.sh screenshots` (about 21 s) | `screenshots: saved 01-title.png, 02-game.png, 03-pause.png, 04-game-over.png, 05-stage-clear.png, 06-skid-low-fuel.png in <repo>/docs/screenshots` | 0 |
| `tools/run_tool.sh scalecheck` (five windows, about 30 s) | `scalecheck: 5 windows passed` | 0 |

`tools/run_tool.sh` reads `${GODOT:-godot}` as `tools/test.sh` does, and the screenshots and scalecheck need
`xvfb-run`.

- **Use `tools/run_tool.sh` wherever the exit code matters (CI).** For each tool it imports the project (a failed
  import is retried once), runs the plan §6 command (smoke: `timeout 300 $GODOT --headless --fixed-fps 60 --path . -s
  res://tools/smoke.gd -- --scenario=1p --frames=10800`; the other two under `xvfb-run -a -s "-screen 0 WxHx24"` with
  `--rendering-driver opengl3 --fixed-fps 60`), shows its output, and fails on any line starting with `ERROR:` or
  `SCRIPT ERROR:` in the import or the tool's output, as `tools/test.sh` does. Arguments after the tool's name go to
  it after `--` (`tools/run_tool.sh smoke --frames=600`). Exit codes: 0 passed; 1 the tool failed; 2 an ERROR line
  while the tool passed; 3 the import failed twice; 64 bad usage; 124 a run took over 300 s; 127 Godot or `xvfb-run`
  not found.
- **What the bare commands' exit codes cover.** Each tool counts logged errors in process, with a `Logger`
  (`tools/tool_base.gd`), from its start until its `_finalize()`, which the engine calls after it has freed every node,
  and exits 1 if any was logged. It cannot see what the engine prints after that, while it shuts down: leaked RIDs or
  "resources still in use at exit" are only lines in the output, which `tools/run_tool.sh` reads. Checked on a scratch
  copy: with a `PhysicsServer2D.body_create()` and a text-server `create_font()` leaked from `game.gd` `new_game()`,
  the bare smoke command printed `smoke: PASS`, then `ERROR: 4 RID allocations of type 'P11GodotBody2D' were leaked at
  exit.` (and one for the fonts), and exited 0; `tools/run_tool.sh smoke` exited 2. A `push_error()` in an
  `App._exit_tree()` (it runs only at the end) made the bare command exit 1 with `smoke: FAIL: errors logged at the
  end of the run`.
- The bare tool commands need an imported project: on a fresh clone without `.godot/` they stop at once with "the
  project is not imported yet" and exit 1. `tools/run_tool.sh` imports first.
- **The smoke test** (`tools/smoke.gd`, scenario `1p`) ends with:
  ```
  smoke 1p keyboard: game started true, Esc pause/resume true/true, focus pause true, retries with Enter 1
  smoke 1p joypad: A held true, stick left/right true/true, D-pad left/right true/true, Start pause/resume true/true, Start to title true, A on title true, retries with A 1
  smoke 1p: 10800 frames, game overs 3, stage clears 0, errors 0
  smoke: PASS
  ```
  Every event goes through `Input.parse_input_event()` and reaches the game through `App._input()`, as a driver's
  would. The keyboard first: Enter on the title, X held, the arrow keys changing every 2 s, Esc at frames 600 and 660
  (pause, resume), `NOTIFICATION_APPLICATION_FOCUS_OUT` at 900 (must pause), `FOCUS_IN` (must stay paused), Esc
  (resume), and Enter one second after the first game over (must retry). Then a joypad on device 0, from 10 s after
  that retry: the keys go up (the car must drop to low gear), A goes down (high gear and throttle, from the pad alone),
  the left stick and the D-pad take turns steering left and right (each must move the car that way between two frames
  without a skid), Start pauses and resumes, and the tank is set to 0.1 at two points (as the screenshots do), so that
  two game overs come whatever the traffic does: at the first, Start must go to the title and A there must start a
  game; at the next, A must retry. Then no error may have been logged.
- **Each scalecheck run** prints a line about the window (`scalecheck window: 1280x720 at (43, 24) on a 1366x768
  screen, picked by the game`), then compares two still pictures (the title, and a game paused after 400 frames of
  driving) with the window read back from the screen, and checks the title's car against its atlas frame
  (`scalecheck sprite: 0 of 424 pixels of the title's car differ from its atlas frame at 2x`). The five windows of
  `tools/run_tool.sh scalecheck`: `--resolution` 1280x800, 1920x1080 and 1366x768 on a 1920x1080 screen (scale 2, 3, 2;
  picture at (0, 40), (0, 0), (43, 24)); then, with no `--resolution`, the window the game picks on a 1366x768 screen
  (1280x720 at (43, 24)) and on a 1280x800 screen (1280x720 at (0, 40)), each at scale 2 with the picture at (0, 0).
  Godot keeps `--resolution` to itself (it is not in `OS.get_cmdline_args()`), so the size the window must have is
  also passed after `--` as `--window=WxH`; the old check of the window size read `--resolution` and so never ran.
  Checked to fail: with `scale_mode="fractional"` at 1366x768 (556 984 pixels of the title and 440 123 of the game
  differ), with linear canvas filtering (the sprite check: 367 of 424), and on the 1366x768 screen without the window
  fit (the 1920x1080 window is not inside the screen).
- `--selftest` was checked to fail (exit 1, one `selftest: FAIL` line per problem) when drawing code logs an error, and
  when its script loses the second pause press, so the game stays paused (`selftest: FAIL the pause press at tick 310
  did not resume the game`).

### How it fits together

- **Main scene.** `scenes/boot.tscn` is one `Node` with `app.gd`. `_ready()` calls `App.start()`: read `--selftest` and
  `--seed=N` after `--`, `fit_window()`, `boot()` (input map, `LocalInput`, `Atlas.load_all()`), then the title. Tools
  set `seed_override` before adding the node; tests call `start()` themselves, because the test runner works inside
  its `_initialize()`, before the root enters the tree, so `_ready()` never comes there.
- **Window.** project.godot opens a 1920x1080 window (3x). `App.fit_window()` shrinks it when the screen's usable area
  (`DisplayServer.screen_get_usable_rect()`) is smaller: to the largest whole multiple of 640x360 that fits
  (`App.fitted_window_size()`), centred on the usable area, so 1280x720 (2x) on a 1366x768 or 1280x800 screen, or on a
  1920x1080 screen whose taskbar leaves 1040 rows. It leaves the window alone headless, when it fits, when it is not a
  plain window, and when its size is not project.godot's: Godot keeps `--resolution` to itself, so a window of another
  size is how an asked-for size shows.
- **Screens.** A screen is a scene whose root script has `setup(app)`, `frame(steps, delta)` and `on_focus_lost()`.
  `App._switch_to(path)` frees the old screen (`queue_free`), clears latched presses and the clock, instances the
  scene, calls `setup(app)` before `add_child()` (screens build everything in `setup()`, nothing in `_ready()`), and
  returns it. `show_title()` and `start_game()` use it; `current_screen()` returns it.
- **Each frame.** Godot delivers input events first: `App._input()` hands each to `input.handle_event()`, which
  latches pause and confirm presses. Then `App._process(delta)` calls
  `current_screen().frame(clock.advance(delta), delta)`. The game screen runs that many steps, each with
  `app.input.step_bytes(world.players.size())`, and stops early at stage clear or game over. At game over it takes the
  presses itself: confirm starts a new game (`App.next_seed()`: the previous seed + 1), pause goes to the title.
- **Focus.** `App._notification()` turns `NOTIFICATION_APPLICATION_FOCUS_OUT` (and `APPLICATION_PAUSED`, for mobile)
  into `on_focus_lost()`. The game screen latches a `PAUSE` press if the world is running, as Phaser did on blur.
  Godot itself lets go of every held key on focus out, so the player presses them again after resuming (Phaser cleared
  its held keys on blur too).
- **Joypads coming and going.** `App` forwards `Input.joy_connection_changed` to `input.connection_changed()`.
- **Session.** `App.high_score` is the best score this session; each new `World` gets it, and the title shows it.
- **The byte.** `Held` bits (`ACCEL`, `BRAKE`, `LEFT`, `RIGHT`, `HIGH_GEAR`) from each device are OR-ed, and
  `Held.to_byte(mask, presses)` makes the `PlayerInput` byte. Bytes are never OR-ed: "left" (steer bits 0) OR "none"
  (1) would read as "none".
- **Drawing.** `game.gd` `render()`: `road.set_scroll(Cars.camera_px(world))`, `cars.show_world(world)`,
  `hud.show_world(world, best, message)`. Each draws in `_draw()` with `draw.gd`, at whole pixels. Screen y of a front
  edge is `Cars.screen_top(world, y_world) = floor(anchor) + round(camera_y) - round(y_world)`: the camera car is
  always on the anchor line, and objects standing on the road move with the road tiles pixel for pixel (never more
  than 1 px from the float `World.screen_y()`). Sprite bodies (frame minus the 1 px shadow) are centred on the
  hitbox at 2x (`Draw.place_on_hitbox()`): cars, the truck and oil land at x - 1, a skidding car at (x - 6, y - 1).
  Animation runs on `world.stage_ticks`: the blink (hidden on even 6-tick blocks while invulnerable), the rainbow (4
  degrees a tick) and the low-fuel warning, so all three freeze while paused. A missing frame draws its hitbox as a
  flat rectangle.

### Input mapping (`scripts/input/`)

- Keyboard, by physical key (`Keyboard.ACTIONS`, built by `Keyboard.build_input_map()` into actions `kb_throttle`,
  `kb_high_gear`, `kb_brake`, `kb_left`, `kb_right`, `kb_confirm`, `kb_pause`): Up/W/Z throttle; X high gear and
  throttle; Down/S brake; Left/A and Right/D steer; Enter, keypad Enter and Space confirm; Esc and P pause. Key
  repeats are not presses.
- Joypads, per device with `Input.is_joy_button_pressed()` and `Input.get_joy_axis()` (`Pads.held_of(device)`): D-pad
  or left stick (beyond 0.5) steers, up is throttle, down brakes; A is high gear and throttle; B throttle. Presses
  come from `InputEventJoypadButton` events (`Pads.press_bits(event)`): A confirms, Start pauses and confirms. Devices
  become known from `Input.get_connected_joypads()`, from `Input.joy_connection_changed` (the app forwards it to
  `LocalInput.connection_changed()`, which tells `pads`) and from their first event, since the connected list is empty
  without a display.
- `LocalInput` (single player): `handle_event(event)`, `connection_changed(device, connected)`, `held()`, `step_byte()`,
  `step_bytes(seats)` (seat 0 gets the byte, other seats `NONE`), `take_presses()`, `press(bits)` and
  `clear_presses()`.

### For A3: CI

- Run `tools/test.sh`, then `tools/run_tool.sh smoke`, both with `GODOT` set to the Godot 4.7.2 binary. Do not run the
  bare smoke command in CI: its exit code misses ERROR lines printed while the engine shuts down (see Verify). The
  wrapper imports the project itself, so the smoke step also passes on a fresh clone (plan §8, A3).
- The `--main-pack build/fuel_rivals.pck -- --selftest` run of plan §6 needs the same check on its output (`grep -E
  '^(SCRIPT ERROR|ERROR):'`), which `tools/run_tool.sh` does not cover.

### For B2: where seats, HUD panels and join screens plug in

- **Seats.** `App.input` is declared `var input: LocalInput` (`scripts/app/app.gd`), so make `scripts/input/seats.gd`
  extend `scripts/input/local_input.gd` and override what differs: `handle_event()` (a join is an
  `InputEventJoypadButton` with A from an unassigned `event.device`), `connection_changed()` (a disconnected seat's
  byte becomes `PlayerInput.BOT`, plan §5), `step_bytes(seats)`, `take_presses()`, `press()`, `clear_presses()` and
  `held()`; then give it to `App.input` for versus games. If seats.gd cannot extend it, retype `App.input` and keep
  those methods and the `pads` member: the app calls `handle_event()` (from `_input()`) and `connection_changed()`
  (from `Input.joy_connection_changed`), and `tools/smoke.gd` and `tests/test_app.gd` read `app.input.pads.devices`
  and `app.input.held()`. Reuse `Pads`: `presses_of()` notes each device and `press_bits()` gives its presses,
  `held_of(device)` its held bits, `Held.to_byte()` the byte.
- **Join and results screens.** New scenes with `setup(app)`, `frame(steps, delta)` and `on_focus_lost()`, opened with
  `App._switch_to("res://scenes/join.tscn")` (add `show_join()` and `show_results()` next to `show_title()`). The title
  screen's confirm press goes to `app.start_game()` today (`title.gd` `start()`).
- **Six cars.** `cars.gd` draws every live car in `world.players` with `Cars.player_sprite(car)`, which only knows
  `car_red`. Add the six recoloured frames to `Atlas.frames` (any `Texture2D`, as `pixel_art.gd` does for the truck)
  and pick them by `car.slot` there. `Cars.screen_top()` already uses `world.anchor`, so the versus anchor (192) needs
  nothing more.
- **HUD.** `hud.gd` draws the two single-player panels (`ViewConfig.PANEL_LEFT`/`PANEL_RIGHT`, 112 x 344 on the grass
  outside x 168-472, rows at the screen y of `HUD_ROW_Y`). For six seats split each side into three panels and draw
  each with the static pieces: `Hud.draw_panel()`, `draw_row()`, `draw_gauge()` (full height, from `GAUGE_TOP` to
  `GAUGE_BOTTOM`; for a shorter one call `Draw.gauge(ci, rect, fraction, fill)`), `draw_message()`, `overlay_rect()`
  and `draw_overlay()` for round and match panels. Text sizes must be one of `ViewConfig.TEXT_SIZES` (`tests/test_view.gd` checks it), and
  `Draw.text_width()` measures a line (the font is 8 px per character at size 8).
- **Game screen.** `game.gd` already steps with `app.input.step_bytes(world.players.size())`; the versus loop differs
  only in what happens at the end of a round.

### Screenshots (`docs/screenshots/`, the 640x360 viewport scaled 2x with Nearest)

- `01-title.png`: the title over the still road, the keyboard and gamepad controls in boxes on the grass, START, the
  player's car in its start lane, the prompt at full brightness and the best score.
- `02-game.png`: a game in high gear at 260 km/h with cars and trucks spread over the six lanes, the "PASS +50"
  message, and both HUD panels (score 50, stage 1, the goal gauge, speed, gear, fuel 87 and its gauge).
- `03-pause.png`: paused one tick after 02 (260 → 261 km/h: the Esc sent after 02 reaches the game a frame later),
  the screen dimmed under the PAUSED panel.
- `04-game-over.png`: the game-over panel (score, best, retry or title) after the tank was set to 0.1; the fuel number
  is 0 in light red.
- `05-stage-clear.png`: the STAGE 1 CLEAR panel (fuel bonus +2910, score, next stage) after the car was set just short
  of the goal.
- `06-skid-low-fuel.png`, staged: the player's 45-degree skid frame with an oil patch just behind the car (its top at
  screen y 320, 4 px below the car's rear), the "OIL! STEER INTO THE SLIDE" message, the light-red fuel number, gauge
  and "LOW FUEL" warning, the fuel car in its rainbow tint (magenta at that tick), a truck and a yellow car.

All six were looked at, also as 1:1 and enlarged crops: sprites sit on whole pixels with no seams between tiles, no
blur, the pixel font is sharp, and no text overlaps another (messages are hidden while a panel is up; panels are
opaque). After the A2 fixes they were made again with `tools/run_tool.sh screenshots`, looked at again, and came out
byte for byte the same.

### The view checks of `tests/test_assets.gd` see the view

- `test_frames_used_by_the_view_exist` now counts every literal that looks like a frame name and, since
  `res://scripts/view` exists, fails unless it found at least one. It finds 18: `car_red`, `car_red_ccw45`,
  `car_red_cw45`, `car_small_yellow`, `car_salmon`, `car_blue`, `car_police`, `truck`, `oil_puddle`, `grass_bush`, the
  five road tiles and the three grass tiles.
- `test_view_scales_are_whole_numbers` reads every value given to a name containing "scale": a number, a constant,
  `Vector2(a, b)`, `Vector2.ONE * a` or `a * Vector2.ONE`, with a and b numbers or constants defined in the view's
  files (looked up, also qualified like `ViewConfig.SPRITE_SCALE`). Anything else, such as a variable or a call, fails
  as unreadable. It must find at least one; it finds 3 (`SPRITE_SCALE`, `TILE_SCALE`, `BUSH_SCALE`, all 2). The view
  never sets a node's `scale`: it draws with `draw_texture_rect()` at frame size x those constants.

### Deviations from the plan, with reasons

- **More files than plan §2 lists**: `scripts/app/{fixed_step,title,game}.gd`, `scripts/input/{held,local_input}.gd`,
  `scripts/view/{draw,pixel_art,title_view}.gd`, `tools/tool_base.gd`, `tools/run_tool.sh`. Each has one job (the
  accumulator is tested on its own; the three tools share their boot, keys and error count; the wrapper applies the
  error filter).
- **The smoke test's error filter.** Plan §6 has `tools/smoke.gd` apply `tools/test.sh`'s filter. In process it can
  count errors only until the engine starts shutting down, so the filter on the whole output is applied by
  `tools/run_tool.sh` around the plan's command, which stays as the plan writes it.
- **The smoke test's timeline** adds a joypad leg after the plan's keyboard one, so after the first game over the
  pad's Start and A answer the game overs instead of Enter. It sets the tank to 0.1 twice, as the plan's screenshots
  do, so the pad's two game overs do not depend on the traffic.
- **The window fit** (`App.fit_window()`): project.godot's 1920x1080 window is used only where it fits the screen.
- **`project.godot` main scene**, added: the game cannot start without one (`--selftest`, A3's `--main-pack` run).
- **Look, where 16:9 or legibility asked for it**: the HUD lives in two side panels (Phaser had a top bar and two
  small panels); panels at 85 % black (Phaser 75 %) and opaque overlay boxes (Phaser 92 %), so the grass and cars do
  not show through text; gear reads `LOW`/`HIGH` (Phaser `L`/`H`); a blinking `LOW FUEL` warning; the stage-clear
  panel adds the fuel bonus line; event messages are hidden while a panel is up; lane dashes are 2 x 14 px every 24 px
  and bushes repeat every 72 px (Phaser's 40/24/4 and 120 px x K, on whole pixels); the title's controls are two
  boxes, keyboard and gamepad, either side of the road.
- **Keypad Enter** also confirms.
- **`--selftest`** fixes its first seed to 1 unless `--seed=N` is given, so it is repeatable, and draws 120 frames of a
  driven game after its checks, so drawing code runs in the exported game too.
- **Screenshot 06 is staged** (traffic placed, a skid and low fuel forced), to show in one picture what a still of
  normal play rarely does. 04 and 05 are forced as the plan says (fuel 0.1; the car near the goal).

### Known gaps, not verified here

- No physical joypad: per-device reading, the stick threshold and A/B/Start were checked with synthetic
  `InputEventJoypad*` events only, in the tests and, through the engine to `App._input()`, in the smoke test.
- Focus: the smoke test and the tests send `NOTIFICATION_APPLICATION_FOCUS_OUT`/`IN` through the SceneTree, as the OS
  layer does. A real X11 focus change was tested by the A2 verifier, not here: the game paused about 250 ms after the
  focus went out, provided the window had focus first.
- The window fit was checked under Xvfb without a window manager, where the usable area is the whole screen and windows
  have no decorations. Decorations are not counted (their size is not known when the game starts), so a title bar can
  push a fitted window's bottom edge under a taskbar. A 1920x1080 desktop with a taskbar gets a 1280x720 window; 3x
  then needs fullscreen, which the game has no key or option for (and fullscreen could not be tried here: without a
  window manager, Xvfb ignores `--fullscreen`). `--resolution 1920x1080` on a smaller screen looks like the default
  and is shrunk too.
- Pictures were checked on Mesa llvmpipe (OpenGL 4.5) under xvfb only; not on a GPU, Windows, or above 1920x1080.
- `NOTIFICATION_APPLICATION_PAUSED` (mobile) pauses the game like a focus loss but was not exercised.
- A mouse click or touch on START works through `title.gd` `_unhandled_input()`; tested by calling it with a
  synthetic click, not with a real pointer.
- The road draws about 1 000 tiles a frame with `draw_texture_rect()`. That is cheap on any GPU, and the whole
  screenshot command takes about 16 s on llvmpipe, but frame times were not measured.

## Lead notes after A2 (verified, committed)

The A2 adversarial verify passed in round 2. Its remaining minor findings are hand-offs:

**For A3**
- Run the tools through `tools/run_tool.sh` (it imports, applies the error filter and maps exit codes). `scalecheck`
  without `-- --window=WxH` checks the window the game picks for the screen, so `--resolution` alone fails on purpose.
- When an error is logged after a tool printed `smoke: PASS`, `_finalize()` prints `FAIL` and exits 1. The exit code is
  right; the earlier PASS line is misleading. Print PASS from `_finalize()` instead, if cheap.

**For B2**
- `game.gd` `new_game()` builds `World.new(cfg, app.next_seed(), 1, app.high_score)`. The versus game must build a
  multi-seat World there (or in a new versus screen) from the join screen's seats.
- The view reads these World fields: `phase`, `stage`, `stage_ticks`, `goal`, `high_score`, `events`, `traffic`,
  `player()`/`players`, and the camera (`camera_y`, anchor). New multiplayer fields the HUD needs must be added to
  `to_array()` too.
- There is no fullscreen toggle yet (see A2 known gaps). Add one (F11 / Alt+Enter, and a title option) with the
  6-player HUD, since 3x on a 1080p desktop needs it.
- New games use the previous seed + 1 (`App.next_seed()`), a deviation from Phaser's random seed per game. Keep it:
  it makes a session reproducible from its first seed.
- The smoke test never reaches the stage-clear branch in 10 800 frames; the screenshot tool covers that panel.

## A3: export presets, pack export check, CI and README

### Files

- **New:** `export_presets.cfg` (written by the 4.7.2 editor itself, see below), `tools/export_check.sh` (mode 100755)
  and `.github/workflows/ci.yml`.
- **Rewritten:** `README.md`, for the Godot project: the game and its state, how to run it, the controls and rules
  as `scripts/input` and `scripts/sim` implement them, tests and tools, export, layout, assets and licences, Steam.
- **Files of other agents that A3 edited** (the lead's A2 note on the PASS line):
  - `tools/tool_base.gd` (A2): `finish(code, pass_line := "")`. With exit code 0 it keeps `pass_line`, and
    `_finalize()` prints it at the very end, only if no error was logged after `finish()`; otherwise it prints
    `<tool>: FAIL: errors logged at the end of the run` as before. `finish(code)` alone works as before.
  - `tools/smoke.gd` (A2): `_report()` prints `smoke: FAIL` at once when the run fails and gives `smoke: PASS` to
    `finish()`.
  - `tools/screenshots.gd` (A2, lead after the A3 review): its "screenshots: saved ..." line is the pass line too.
  - Tested by `tests/test_tools.gd` (lead after the A3 review): `_finalize()` runs only when a tool's own process
    shuts down, so the test runs `tests/fixtures/pass_line_tool.gd` in a child Godot (`OS.execute`) and checks the
    pass line and exit 0, then, with an error logged right after `finish()`, exit 1, the FAIL line and no pass line.
    Printing the pass line in `finish()` again makes the second test fail. The exit code, not the line, is still the
    verdict: what the engine prints while it shuts down only `tools/run_tool.sh` catches.
- Nothing under `scripts/` changed: the game runs from the pack as it is.

### Verify

| Command | Last line | Exit |
|---|---|---|
| `GODOT=/tmp/claude-0/godot/Godot_v4.7.2-stable_linux.x86_64 tools/test.sh` | `173 passed, 0 failed` | 0 |
| `tools/run_tool.sh smoke` (about 22 s) | `smoke: PASS` | 0 |
| `tools/export_check.sh` (about 12 s: the import, the export, the pack's file list, the self test) | `export_check: PASS` | 0 |
| The three, in that order, in a copy of `git ls-files -co --exclude-standard` (no `.godot/`, no `build/`) | the same | 0 |
| `tools/run_tool.sh smoke` and `tools/export_check.sh`, each alone in such a copy | the same | 0 |
| The three in such a copy with an empty `HOME` (no editor settings or caches, as on a CI runner) | the same | 0 |
| `tools/run_tool.sh screenshots` and `scalecheck` in such a copy (both extend `tools/tool_base.gd`) | `screenshots: saved ...` (the six pictures byte for byte the same as the committed ones); `scalecheck: 5 windows passed` | 0 |

`tools/export_check.sh` prints, on success:

```
export_check: exported build/fuel_rivals.pck with the "Linux" preset (111996 bytes)
export_check: build/fuel_rivals.pck holds 66 files, none under tests/, tools/ or docs/, with project.binary and assets/font/OFL.txt
Godot Engine v4.7.2.stable.official.ed1daf0bf - https://godotengine.org

selftest: ok (600 ticks checked, 120 frames drawn)
export_check: PASS
```

Exit codes: 0 passed; 1 the export failed, the pack's file list is wrong or the self test failed; 2 an ERROR line
while everything else passed; 3 the import failed twice; 64 bad usage (it takes no arguments); 124 a run took more
than 300 s; 127 Godot not found. Checked to fail, each on a scratch copy unless said:

| Change | Exit | Output |
|---|---|---|
| `push_error()` in `App._begin_selftest()`, in the repository (then restored: same SHA-256, `git diff` clean) | 1 | `selftest: FAIL ...`, `the self test from build/fuel_rivals.pck failed (exit 1)`, the ERROR line |
| `exclude_filter` without `tests/*` | 1 | the `tests/` files found in the pack |
| `include_filter=""` | 1 | `build/fuel_rivals.pck has no assets/font/OFL.txt` |
| preset name `Linux Typo` | 1 | Godot's `ERROR: Invalid export preset name: Linux Typo.` |
| `push_error()` in an `App._exit_tree()`, printed after the self test passed | 2 | the ERROR line |
| a pack without `scripts/view/`, with `TIMEOUT` cut to 20 s | 124 | `SCRIPT ERROR` lines: the game cannot start from that pack and hangs |
| `GODOT=/nonexistent/godot`; an argument | 127; 64 | the reason |

Its pack reader (`pack_files()`) also rejects at once a truncated pack, a huge file count, a directory offset outside
the file, pack format 3, a corrupted path length and a file that is not a pack.

The PASS line of the tools, before and after the change:

| Run | Before | After |
|---|---|---|
| `tools/run_tool.sh smoke` | `smoke: PASS` last, exit 0 | the same |
| `tools/run_tool.sh smoke --scenario=1p --frames=600` (too short, fails) | the `smoke: FAIL ...` reasons, `smoke: FAIL`, exit 1 | the same |
| The same command as the first row, with a `push_error()` in an `App._exit_tree()` (scratch copy) | `smoke: PASS`, then `smoke: FAIL: errors logged at the end of the run`, exit 1 | no PASS line, only the FAIL line, exit 1 (also the bare smoke command) |

### The pack check (`tools/export_check.sh`)

1. Imports the project, as `tools/test.sh` does.
2. `rm -f build/fuel_rivals.pck`, then `timeout 300 godot --headless --path . --export-pack "Linux"
   build/fuel_rivals.pck` (after `mkdir -p build`: Godot does not create a missing folder, it fails with `Save PCK:
   Can't open file for writing`). The export's output is shown only when it fails.
3. Reads the pack's directory with `od`, `tail` and `head` (Godot has no command that lists a pack). Godot 4.7.2
   writes pack format 4: a 112-byte header ("GDPC", the format, 4, 7, 2, the flags, the file base and the
   directory's offset), the files, then the directory at the end (per file: the path length padded to 4, the path
   without `res://`, offset, size, MD5, flags). The reader stops if the directory does not end exactly at the end of
   the file. It fails on any file under `tests/`, `tools/` or `docs/`, and when `project.binary` or
   `assets/font/OFL.txt` is missing.
4. Runs `timeout 300 godot --headless --main-pack <repo>/build/fuel_rivals.pck -- --selftest` from an empty
   temporary directory, and needs exit 0 and a `selftest: ok` line. **From the project directory the run proves
   nothing:** Godot reads a `res://` file that the pack lacks from the working directory, so a pack without
   `scripts/view/` passed there (`selftest: ok`, exit 0, WARNING lines only: `invalid UID ... using text path
   instead`). From an empty directory the same pack fails.
5. Fails on `ERROR:` and `SCRIPT ERROR:` lines in the import, the export or the run.

The pack holds 66 files: the scripts as `.gdc` (compressed binary tokens, `script_export_mode=2`) with their
`.gd.remap`, the three scenes converted to binary under `.godot/exported/`, the imported atlas, font and icon under
`.godot/imported/` with their `.import` files, `assets/sprites.json`, `assets/font/OFL.txt`, `icon.svg`,
`project.binary`, `.godot/uid_cache.bin` and `.godot/global_script_class_cache.cfg`. No `.gd` source and nothing from
`tests/`, `tools/` or `docs/`.

### `export_presets.cfg`

- Two presets, as plan §6 describes for B3: **Linux** (`build/linux/fuel_rivals.x86_64`) and **Windows Desktop**
  (`build/windows/fuel_rivals.exe`), each with `binary_format/embed_pck=true`,
  `exclude_filter="tests/*, tools/*, docs/*"` and `include_filter="assets/font/OFL.txt"`. Every other value is the
  4.7.2 default. A pack export with the Windows Desktop preset gives the same 66 files.
- The 4.7.2 format differs from older Godot files: a `[runnable_presets]` section maps each platform to its runnable
  preset (no `runnable=` key per preset), there are `patch_delta_*` keys, and `[preset.N.options]` lists every option
  of the platform.
- **How it was made:** on a scratch copy of the repository, a throwaway editor plugin (enabled in that copy's
  `project.godot`) registered an `EditorExportPlugin`, collected each platform from its `_get_export_options()`, and
  set `binary_format/embed_pck` on each preset from `EditorExportPlatform.get_current_presets()`, which makes the
  editor save the file. The headless editor (`--editor`) loaded a short hand-written file and saved the full one.
  Loading that output and saving again gave the same bytes.
- Edit presets in the editor (Project > Export). Godot rewrites the whole file, so comments there would be lost.
- `--import` and `--export-pack` runs leave it byte for byte unchanged (checked by checksum after them), and print
  nothing about it. When the editor does save it, the bytes stay the same (the second pass above).

### CI (`.github/workflows/ci.yml`)

- On `push` and `pull_request`; `permissions: contents: read`; no secrets; `ubuntu-24.04`; 30-minute job timeout;
  `shell: bash` (`bash --noprofile --norc -eo pipefail`).
- Steps: `actions/checkout@v7` (`persist-credentials: false`); `actions/cache/restore@v6` of
  `Godot_v4.7.2-stable_linux.x86_64.zip`, key `godot-4.7.2-stable-linux-x86_64`; on a miss, `curl` from
  `https://github.com/godotengine/godot/releases/download/4.7.2-stable/`; **every run** downloads the release's
  `SHA512-SUMS.txt` and checks the zip (`sha512sum --check --strict`), so a cached zip is checked too;
  `actions/cache/save@v6` right after the check, so a failing test does not throw the download away (the plain
  `actions/cache` saves only when the whole job succeeds); unzip, `--version`, `GODOT` into `$GITHUB_ENV`; then
  `tools/test.sh`, `tools/run_tool.sh smoke` and `tools/export_check.sh`, each `if: ${{ !cancelled() &&
  steps.godot.outcome == 'success' }}`, so one run reports all three; `actions/upload-artifact@v7` uploads
  `build/fuel_rivals.pck` (artifact `fuel_rivals-pck`, 14 days) when the export check passed.
- Action versions: the newest major tag of each (`git ls-remote`): checkout v7 (7.0.0 in June 2026, now 7.0.1),
  cache v6 (6.0.0 in June 2026, now 6.1.0), upload-artifact v7 (7.0.0 in February 2026, now 7.0.2). Each runs on
  node24, and the inputs and outputs used were read from their `action.yml` at that tag.
- **Checked here:** PyYAML parses it; actionlint 1.7.12, with shellcheck 0.11.0 for the `run:` blocks, reports
  nothing (its database knows upload-artifact v7's inputs, but not checkout v7's or cache v6's: those were checked by
  hand); shellcheck is clean on the three shell scripts. A local driver ran every step of the file in order: each
  `run:` block exactly as written with `bash --noprofile --norc -eo pipefail`, the `if:` conditions evaluated, the
  `$GITHUB_ENV` lines passed on, and stand-ins for checkout, cache and upload. Four runs: a cache miss (the real
  78 MB download and `Godot_v4.7.2-stable_linux.x86_64.zip: OK`, then `173 passed, 0 failed`, `smoke: PASS`,
  `export_check: PASS`); a cache hit in a new workspace (no download, the check again, the same results); a corrupted
  cached zip (`FAILED`, every later step skipped, job failed); and a failing test (the smoke test and the export still
  ran and passed, the pack was uploaded, job failed).

### Deviations from the plan, with reasons

- **`include_filter="assets/font/OFL.txt"`**, which plan §6 does not list: a `.txt` file is not a resource, so the
  export left the font's licence out, while ASSETS.md says it ships with the font (the OFL asks for it).
- **The pack runs from an empty directory, with the pack's absolute path**, not as plan §6 writes it from the project
  root: from the root, files missing from the pack are read from the checkout (see "The pack check").
- **CI also runs `tools/export_check.sh`** (plan §6 names `tools/test.sh` and the smoke test; the lead asked for all
  three), and runs the three checks even after one fails.

### Known gaps, not verified here

- **The workflow ran on GitHub** (lead's push of 52d9594, run 39012173681 on ubuntu-24.04): every step green, the
  editor saved in the cache under `godot-4.7.2-stable-linux-x86_64`, `173 passed, 0 failed`, `smoke: PASS`,
  `export_check: PASS`, and the `fuel_rivals-pck` artifact uploaded. Not seen yet: a run that restores the editor from
  the cache (the next push shows it).
- No binary was exported: the export templates are B3's. The presets were loaded and used only for packs.
- The pack ran on the editor binary (`--main-pack`), not on an export template.
- The licence travels inside the pack, where a player cannot read it. For the Steam build (B3), put
  `assets/font/OFL.txt` next to the executable too, or show the credits of ASSETS.md in the game.
- `export_check.sh` reads pack format 4 only (Godot 4.7). A Godot version that changes the format makes it fail with
  `cannot read ...: pack format N`; update `pack_files()` then. It reads integers in the machine's byte order
  (little-endian on x86-64 and ARM). It was run on Linux x86-64 only.
- README claims were checked against the code and by runs (the numbers of the rules by a scratch script that printed
  them from `scripts/sim`; the window under xvfb; `--seed`, `--selftest`, `--only`; the failed selftest without an
  import). Opening the project in the editor's GUI was not tried.

### For the next agents

- **B1, B2:** CI runs `tools/test.sh` on every push, so new tests run there without changes. Keep the three scripts
  the entry points. `README.md` describes phase A: update its State, Controls and Rules sections when phase B lands.
- **B3:** the presets are ready: `mkdir -p build/linux build/windows`, install the 4.7.2 templates, then
  `--export-release "Linux" build/linux/fuel_rivals.x86_64` and `--export-release "Windows Desktop"
  build/windows/fuel_rivals.exe` (not tried here). New smoke scenarios can end with `finish(0 if ok else 1,
  "smoke: PASS")` to get the same PASS line. If CI should run the scenarios, add them to `ci.yml` after the smoke
  step.
- **B4:** a Steam build adds `addons/godotsteam/` to the pack; a build without Steam adds `addons/godotsteam/*` to
  `exclude_filter` (plan §5). If the GodotSteam import prints ERROR lines on a first import, all three scripts fail
  on them; narrow the filter in all three and note it here. `tools/export_check.sh` checks only the Linux preset.

## B1

### Part 1 (agent B1a): the versus rules in the simulation

The versus mode of plan §7, in the pure simulation: the versus world and its round, camera, bottom edge, contacts,
points, denser traffic, eliminations, the round's winner, pause, disconnected seats and each seat's own RNG stream.
The match (best of three), bot.gd and the versus golden checksum are part 2 (B1b); no UI (B2).

#### Files

- **Simulation** (B1's): `scripts/sim/world.gd` (the versus mode next to the stage mode), `scripts/sim/config.gd`
  (the versus values).
- **Tests** (28 new, 201 in all): `tests/test_versus.gd` (13: the versus world, camera, bottom edge, contacts,
  points, gaps), `tests/test_versus_round.gd` (10: eliminations, round end, winner, pause, disconnect, bot hook),
  `tests/test_versus_rng.gd` (5: seat streams, the traffic with 2 or 6 seats, restore, determinism). Together they
  hold the 19 test names of plan §8 B1 that are not match-level.
- **Files of other agents edited**, each with tests:
  - `scripts/sim/car.gd` (A1): four fields at the end, `human`, `distance`, `touching_edge` and `rng` (the seat's
    own `Rng`), in `to_array()` (its state as one u32), `from_array()` and `clone()`; `World.FORMAT` is now 2. Tested
    by `tests/test_world_state.gd` (coverage, round trip, checksum) and the versus tests.
  - `tests/test_world_state.gd` (A1): `_numeric_targets()`, `_same_owner()` and `_dump()` include each seat's `Rng`,
    so `test_every_field_round_trips_and_moves_the_checksum` covers the seat streams; `test_to_array_covers_every_field`
    checks a seat `Rng` is one u32.
  - `tests/test_seats.gd` (A1): `test_two_players_same_inputs_identical` is now
    `test_two_players_same_inputs_identical_while_neither_draws`, as the lead's note after A1 asks: its comment states
    the narrowed property (same bytes give identical seats only while no seat draws from the world RNG) and it asserts
    the world RNG did not move. The plan §6 name is its prefix, so `--only=test_two_players_same_inputs_identical`
    still finds it. The general case is `tests/test_versus_rng.gd::test_traffic_same_for_2_and_6_seats`.
  - `tests/sim_helpers.gd` (A1): `quiet_versus()`, `quiet()`, `place()` and `run_bytes()`; `quiet_world()` now calls
    `quiet()` (the same three gaps).

#### Verify

| Command | Last line | Exit |
|---|---|---|
| `GODOT=/tmp/claude-0/godot/Godot_v4.7.2-stable_linux.x86_64 tools/test.sh` | `201 passed, 0 failed` | 0 |
| The same after `rm -rf .godot` | `201 passed, 0 failed` | 0 |
| `tools/test.sh --only=test_versus` (the three versus files) | `28 passed, 0 failed` | 0 |
| `tools/run_tool.sh smoke` | `smoke: PASS` | 0 |

- Single player is unchanged: `tests/test_golden.gd` (the Phaser trace of 10 800 ticks, compared as A1 set it up)
  and every A1/A2 test pass. Every changed single-player code path goes through a helper that does what the old line did in
  `MODE_STAGES` (`_seat_rng()` is the world RNG, `_next_gap()` is `Traffic.next_gap()`, `_blue_target()` returns
  the first seat in reach, `_lane_target()` draws only when no blue target).
- **Checked to fail.** Each rule was broken on purpose, one at a time (52 edits of `world.gd` and `config.gd`, with
  a scratch script that is not committed), and each broken version failed the test written for that rule, among
  others. Examples: fuel cars or blue cars going to the first seat in seat order, either tie going to the higher seat,
  no speed for a held car, no 351.5 tolerance, distance or pass points while touching, the shrink every 1201 ticks or
  counting paused steps, a 56.25 px floor, scaled fuel-car gaps, eliminations one at a time, the round ending mid-step
  or on a bot, each tie-break removed, a tie won by the lower seat, bots as candidates, the single-human rule removed
  or counting dead bots or fuel, a bot seat's byte pausing, the hook called before the pause check or for seats that
  are out, world-RNG draws for the seats, the camera moving back, one struck mask for all seats, oil leaving after the
  first car or before the step's eliminations, trucks hitting invulnerable cars.

#### Public versus API (for B1b and B2)

**Making one.** `World.versus(cfg, seed, seats, humans)`: `cfg` is `Config.standard()`, `seats` 2 to 6, `humans` a
mask with bit `1 << seat` for each person's seat (at least one, none past the last seat). It returns null, with an
error, unless `World.versus_valid(cfg, seats, humans)` is true; the join screen can ask that first (with one human it
must add at least one bot, plan §7). Seat `s` starts in lane `Config.VERSUS_START_LANES[seats][s]` (2 seats: 1, 4;
3: 1, 3, 5; 4: 0, 2, 3, 5; 5: 0, 1, 3, 4, 5; 6: all), on the anchor line, stopped in low gear with a full tank.
`World.new(cfg, seed, seats, 0, World.MODE_VERSUS, humans)` is the same without the check (for subclasses in tests).
`start_round()` starts the next round on the same world (below).

**Each step.** `step(bytes)`, one byte per seat. `0xFF` hands the seat to the bot hook: send it for every bot seat
and for a human seat whose pad went away. Any other byte drives its seat, whatever the seat's human flag; a missing
byte is no input, not a bot. A pause press from a human seat (byte not `0xFF`) pauses a running round and resumes a
paused one; a bot seat's byte never pauses. The world takes no confirm press in versus, and no input once the round
is over.

**Phases and events.** `phase` is `RUNNING`, `PAUSED` or `ROUND_OVER` (4, new; `STAGE_CLEAR` and `GAME_OVER` never
happen in versus). New event bits: `EV_OUT` (1024, in the seat's `events` and the world's: the seat went out this
step) and `EV_ROUND_OVER` (2048, world). `PHASE_NAMES` and `EVENT_NAMES` are unchanged (see deviations);
`ALL_PHASE_NAMES` and `ALL_EVENT_NAMES` name every code. `start_round()` clears `events`, so read a step's events
before starting the next round.

**Per seat (`Car`), what the HUD needs:**

| Field | Meaning |
|---|---|
| `alive` | 1 in the round, 0 once out. A car that is out stays in `players` (seats keep their index), frozen, and is not drawn (cars.gd draws live cars only), moved, pushed, collided with or followed by the camera. |
| `human` | 1 for a person's seat, 0 for a bot's. Fixed: a human seat driven by the hook after a disconnect stays 1. |
| `score` | Points this round: +50 a pass, +1000 a fuel car, +10 per 100 px of `distance`. |
| `fuel` | 0 to 100. A seat that is out with fuel 0 ran dry; one with fuel left met a truck. |
| `distance` | px of world driven while not touching the bottom edge (speed x K x dt a step). |
| `touching_edge` | 1 if the car touched the bottom edge in the last running step (it then loses 3 fuel a second). |
| `events` | The seat's `EV_*` bits of the last step (skid, bump, crash, spin, pickup, pass, out). |
| `slot`, `x`, `y_world`, `speed`, `gear`, `slide_vx`, `invulnerable` | As in single player. |
| `rng` | The seat's own stream (below). |

**World fields.** `mode` (`MODE_VERSUS` = 1), `phase`, `winner` (the seat that won, or `NO_WINNER` = -1; set when the
phase becomes `ROUND_OVER`), `events`, `camera_y`, `anchor` (192), `stage_ticks` (running ticks this round: the view's
animation clock and the difficulty clock), `gap_scale` (the car and oil gap factor), `players`, `traffic`, `tick`,
`game_seed`. There are no stages: `stage` stays 1 and `goal` 0 (hud.gd already guards a goal of 0). `high_score` is
left alone in versus.

**Static helpers.** `World.versus_valid(cfg, seats, humans)`, `World.seat_seed(game_seed, slot)` (a slot's stream
seed), `World.versus_gap(cfg, gap_kind, gap_scale, rng)` (a versus spawn gap, one draw from `rng`).

**Config names.** Constants: `VERSUS_SEATS_MIN` (2), `VERSUS_SEATS_MAX` (6), `VERSUS_START_LANES`,
`EDGE_FUEL_DRAIN_PER_SEC` (2.0), `VERSUS_DISTANCE_POINTS` (10), `VERSUS_SHRINK_TICKS` (1200), `VERSUS_GAP_SHRINK`
(0.9), `SEAT_SEED_STEP` (0x50000000). Standard-profile fields (0 in the phaser profile): `anchor_versus` (192),
`edge_bottom` (352), `edge_touch` (351.5), `distance_step` (100), `versus_gap_min` (40). Also used:
`POINTS_PER_PASSED_CAR`, `FUEL_CAR_POINTS`, `FUEL_PICKUP`, `blue_reach`, the car, oil and fuel gaps.

#### The rules as built (one running step, in order)

1. Cars move as in single player; a roadside crash's fuel cost comes from the seat's stream.
2. The camera moves up to the live car furthest ahead, human or bot (the lowest seat on a tie), and never back; that
   car's front edge is on y = 192. When it goes out, the camera holds until a live car reaches its line.
3. Bottom edge (`_bottom_edge()`): a live car whose bottom edge would end the step below y = 352 is put back on it and
   its speed becomes `max(speed, camera moved / (K x dt))`. It touches the edge if held, or if its bottom edge is at
   351.5 or lower: then it loses 2 more fuel a second and earns no distance. Every other car adds its own scroll to
   `distance` and earns 10 points for each whole 100 px.
4. Traffic moves and changes lane. A blue car heads one lane toward the live seat in reach (single player's band:
   from the seat's rear edge to 112.5 px ahead of its front) whose centre is nearest its own in y, the lowest seat on
   a tie. A pass pays 50 once per seat; a seat touching the edge uses the pass up and gets nothing.
5. Spawns: car and oil gaps are `(gap + jitter) x gap_scale`, at least 40 px; fuel-car gaps never shrink.
6. Fuel cars first: each one touched this step goes to the touching seat whose centre is nearest its centre
   (straight line), the lowest seat on a tie: +10 fuel, +1000.
7. Other contacts, seat by seat: oil (once per seat; the skid direction from the seat's stream), nothing else while
   invulnerable, a truck puts the seat out, a bump once per seat (a centre-on-centre direction from the seat's stream).
8. An empty tank puts the seat out. Every seat out this step leaves at once (`alive` 0, `EV_OUT`); then an oil patch
   leaves once every seat still in the round has used it.
9. `stage_ticks` + 1; at every 1200th running tick `gap_scale *= 0.9` (paused steps do not count).
10. End of round: a human seat out this step (also one the hook drives), or, with a single human seat, no bot left.
    The phase becomes `ROUND_OVER` at the end of the step, after everything above, with `EV_ROUND_OVER`.

**The winner is chosen by World** at the end of the round (`winner`), so match.gd only reads it. Candidates: the
human seats still alive after the step or, when none is, the human seats that went out in that step. The best has
the most points, then the most `distance`, then the most fuel; level with another candidate on all three: nobody wins.
With a single human seat the human must also beat every bot still alive after the step, on points and then distance
(fuel does not count against bots); a bot level or ahead means nobody wins. Bots never win.

**`start_round()`** puts every seat back in its start lane on the anchor line, alive, stopped, low gear, full tank,
no score, distance, skid or invulnerability; empties the road; draws a new spawner (three world-RNG draws); resets
`gap_scale`, `stage_ticks`, `camera_y`, `phase` (RUNNING), `winner` and `events`. It keeps the world RNG and every
seat's stream (plan §7: "El RNG continúa"), the human flags, `tick` and `game_seed`. `World.versus()` calls it.

**Each seat's own RNG stream.** In versus mode a seat's oil-skid direction, roadside crash cost and
centre-bump direction come from `car.rng`, seeded `World.seat_seed(game_seed, slot) = game_seed + (slot + 1) x
0x50000000`. mulberry32's state moves by 0x6D2B79F5 a draw and 0x50000000 = 2^28 x 0x6D2B79F5 (mod 2^32), so slot
s's stream is the world's stream (s + 1) x 2^28 draws on: no two of the world's and slots 0 to 14 overlap within
268 435 456 draws. In single player every seat still draws from the world RNG, as Phaser did.

**The bot hook (for B1b).** In versus the world calls `_bot_byte(car)` once per step for each live seat whose byte is
`0xFF`, in seat order, on steps that run: after the pause check and before the cars move, so before every other
check of the step. Never on a step that pauses, resumes or is paused, for a seat that is out, or after the round, so
a bot that draws random numbers or keeps a 12-tick reaction delay sees exactly the running steps
(`test_bot_hook_runs_once_per_bot_seat_on_running_steps`). Single player, unchanged from A1, calls it on every step
for every `0xFF` seat. bot.gd must not draw from the world `rng` (it would shift the traffic, which
`test_traffic_same_for_2_and_6_seats` catches); it can use `car.rng` or a stream of its own,
`Rng.new(World.seat_seed(game_seed, slot + Config.VERSUS_SEATS_MAX))`. Bot state must go into `to_array()` (a new
Car or World field; `tests/test_world_state.gd` checks coverage).

#### Deviations from the plan, with reasons

- **Phase and event names.** `PHASE_NAMES` and `EVENT_NAMES` stay Phaser's lists:
  `tests/test_golden.gd::test_golden_file_uses_the_ports_codes` compares them exactly with the golden file's codes.
  The new codes go after them (`ROUND_OVER` 4, `EV_OUT` 1024, `EV_ROUND_OVER` 2048), named in `ALL_PHASE_NAMES` and
  `ALL_EVENT_NAMES`.
- **Lane changes always draw.** In versus a traffic car's lane change draws its random lane even when a blue car
  then heads for a seat instead. With single player's rule (no draw when there is a target) the number of world-RNG
  draws depends on where the seats are, so 2 and 6 seats would not see the same traffic: with that rule,
  `test_traffic_same_for_2_and_6_seats` fails. Per-seat streams alone (the lead's note) were not enough.
- **When the hook runs.** A1 called it on every step before the phase checks. Plan and lead also ask that it never
  run while paused, so versus calls it only on steps that run (still before everything those steps check).
- **The byte decides who drives**, the human flag decides pause, the end of the round and the winner. Plan §3 defines
  0xFF as "a bot drives the seat", so a bot seat is a seat whose byte is 0xFF; B2 must send 0xFF for bot seats. A
  bot seat given another byte is driven by it, which the tests use while bot.gd does not exist.
- **Seat seeds by arithmetic** (`SEAT_SEED_STEP`), because `hash()` is not allowed in `scripts/sim`; the spacing of the
  streams then follows from mulberry32 itself (`test_seat_streams_start_2_pow_28_draws_apart`).
- **Ties on points go to `distance`**, the distance that scores (not `y_world`, which includes being pushed).
- **Fuel cars are settled before the step's other contacts**, so a seat that also meets a truck in that step keeps
  the pickup, and it counts for the winner (needed for the nearest-centre rule anyway).
- **Single human:** "every bot still alive" means after the step, so bots out in the same step do not count; if the
  human and the last bots go out together, the human wins, as when every bot goes out first.
- **"Vertical distance"** for blue cars is centre to centre, inside the band single player already uses; "nearest
  centre" for fuel cars is the straight-line distance (compared squared).
- **The shrink scales new gaps only**: a gap counting down keeps its length. `gap_scale` keeps falling below the floor,
  which applies when a gap is drawn.
- **Profile fields**: the versus px values are standard-profile fields, as `config.gd` keeps px values in profiles;
  the phaser profile has no versus mode (its fields are 0 and `World.versus()` refuses it).
- **`start_round()` is in world.gd**, the round state being World's; `test_round_reset` stays B1b's.
- **Not in the plan, added:** `test_versus_world_starts_in_spread_lanes_on_the_anchor_line`,
  `test_versus_needs_2_to_6_seats_and_a_human`, `test_oil_stays_until_every_live_car_has_used_it`,
  `test_seat_draws_use_the_seats_own_stream`, `test_seat_streams_start_2_pow_28_draws_apart`,
  `test_traffic_same_for_2_and_6_seats`, `test_versus_restore_midway_same_checksum`,
  `test_versus_six_seats_same_checksum_twice` and `test_bot_hook_runs_once_per_bot_seat_on_running_steps`.

#### Known gaps

- **Bots do not drive yet**: `_bot_byte()` still returns no input, so a bot seat stands still, falls back to the bottom
  edge, is pushed along and runs dry in about 33 s (B1b's bot.gd).
- **B1b:** `scripts/sim/match.gd` (first to 2 wins; 1-1-1 capped at 5 rounds, then rounds won and total points; one
  human: 2 wins or 2 losses, B1b to say how a round with `winner == NO_WINNER` counts), `test_first_to_two_and_cap_five`,
  `test_round_reset` and `tests/golden/versus_checksum.txt` (plan §8 B1: 6 seats, 7200 ticks). That run should include
  bot.gd, so it is not written yet; `test_versus_six_seats_same_checksum_twice` already checks the two runs agree and
  can compare with the file once it exists.
- **B2:** no versus screen yet. ROUND_OVER has no panel (`Hud.overlay_for()` shows nothing for it), the HUD shows
  seat 0 only, and `game.gd` builds single-player worlds. Build with `World.versus(Config.standard(),
  app.next_seed(), seats, humans)`, send 0xFF for bot seats and disconnected human seats, and read `winner` and the
  events before calling `start_round()`.
- **Values to tune in play** (DECISIONES §3): `EDGE_FUEL_DRAIN_PER_SEC`, `VERSUS_DISTANCE_POINTS` with
  `distance_step`, `VERSUS_SHRINK_TICKS`, `VERSUS_GAP_SHRINK` and `versus_gap_min`. Not tried by playing.
- In single player a `0xFF` seat still asks the hook on paused steps (A1's behaviour, kept unchanged); it would only
  matter if a bot ever drove a single-player seat.

### Part 2 (agent B1b): the match and the bots

The best-of-three match (`scripts/sim/match.gd`), the bots (`scripts/sim/bot.gd`, hooked into `World._bot_byte()`),
the versus golden checksum and a tool that measures bot play. Part 1's B1b gaps are closed: bots drive, the match
exists, `test_first_to_two_and_cap_five` and `test_round_reset` pass, `tests/golden/versus_checksum.txt` is written.
Still no UI (B2).

#### Files

- **Simulation** (B1's):
  - `scripts/sim/match.gd` (new): rounds of one versus World until the match is decided.
  - `scripts/sim/bot.gd` (new): the bot policy and each bot's state.
  - `scripts/sim/world.gd`: `bots` (one Bot per seat in versus; none in single player), `World.bot_seed()`,
    `_bot_byte()` asks the seat's bot in versus, `start_round()` resets the bots, `to_array()` / `from_array()` /
    `clone()` carry them; `FORMAT` is 3.
  - `scripts/sim/config.gd`: the bot values (`BOT_*` constants, `bot_*` standard-profile fields) and the match values
    (`MATCH_*`).
- **Tests** (26 new, 1 replaced: 226 in all): `tests/test_bot.gd` (16), `tests/test_match.gd` (9),
  `tests/test_versus_golden.gd` (1) and `tests/golden/versus_checksum.txt`.
- **B1's own tests changed** (`tests/test_versus_rng.gd`):
  - `test_traffic_same_for_2_and_6_seats` gives its four trailing bot seats no input (`NONE`) instead of 0xFF. With
    0xFF they used to stand still too (no bot existed); now bot.gd would drive them out of the traffic's way and the
    test would no longer see seats that draw from their own streams. The same property with driving bots is
    `tests/test_bot.gd::test_traffic_does_not_depend_on_the_number_of_bots`.
  - `test_versus_six_seats_same_checksum_twice` is replaced by
    `tests/test_versus_golden.gd::test_six_seats_7200_ticks_match_the_golden_checksum` (two runs and the file, every
    seat driven by bot.gd, through Match).
- **Files of other agents edited** (A1's tests), each checked by the tests it is part of:
  - `tests/test_world_state.gd`: `bots` is a composite field of World; `to_array()` has one more entry; a Bot has one
    `to_array()` entry per field and its Rng one u32; `test_every_field_round_trips_and_moves_the_checksum` also runs
    on a versus world, covering every bot field, each bot's stream and every byte a bot has pending.
  - `tests/test_sim_purity.gd`: the allowed field types include `Bot`, `World` and `Array[Bot]` (`World.bots`,
    `Match.world`); `test_sim_purity` scans the two new files like the others.
- **Tools**: `tools/bot_stats.gd` (bot play measured over seeds, for B3) and `tools/versus_golden.gd` (rewrites the
  golden file).

#### Verify

| Command | Last line | Exit |
|---|---|---|
| `GODOT=/tmp/claude-0/godot/Godot_v4.7.2-stable_linux.x86_64 tools/test.sh` | `226 passed, 0 failed` (about 16 s of tests) | 0 |
| The same after `rm -rf .godot` | `226 passed, 0 failed` | 0 |
| `tools/test.sh --only=test_bot.gd,test_match,test_versus_golden` | `26 passed, 0 failed` | 0 |
| `tools/run_tool.sh smoke` | `smoke: PASS` | 0 |
| `$GODOT --headless --path . -s res://tools/bot_stats.gd` (about 65 s) | `bot_stats: ran in 65.6 s` (the time varies; numbers below) | 0 |
| `$GODOT --headless --path . -s res://tools/versus_golden.gd` (only to regenerate, below) | `versus_golden: wrote <repo>/tests/golden/versus_checksum.txt` | 0 |

Single player is unchanged: `tests/test_golden.gd` and every A1/A2 test pass; in single player `_bot_byte()` still
returns no input and the world has no bots.

#### The match (`match.gd`): API for B2

**Making one.** `Match.create(Config.standard(), seed, seats, humans)`, with `World.versus()`'s arguments (null, with
an error, unless `World.versus_valid()`; the join screen can ask that first). `match.world` is the one World of the
whole match: B2 draws it as in part 1, and it is the same object from round to round.

**Each fixed step.** `match.step(bytes)`, one byte per seat, as `World.step()`: the pad's byte for a connected
human seat, `PlayerInput.BOT` (0xFF) for a bot seat and for a human seat whose pad went away. The world steps in every
phase (it counts the tick; between rounds it takes no input). Pause stays the world's (`world.phase == PAUSED`, any
human's Start).

**Phases** (`phase`, `Match.PHASE_NAMES`) and events of the last step (`events`, `Match.EVENT_NAMES`):

| Phase | Meaning |
|---|---|
| `PLAYING` (0) | A round is under way (the world is RUNNING or PAUSED). |
| `ROUND_OVER` (1) | The round ended and the match is not decided. Entered with `EV_ROUND_OVER` (1). |
| `MATCH_OVER` (2) | The match is decided. Entered with `EV_ROUND_OVER` and `EV_MATCH_OVER` (2) together. It takes no input any more. |

`EV_ROUND_START` (4): a confirm press started the next round on this step; that round's first step is the next one.

**What the results screens read:**

| Field or method | Meaning |
|---|---|
| `round_number` | The round being played, or just played: 1 for the first. |
| `last_round_winner()` | The last finished round's winner (`world.winner` until the next round starts), or `Match.NO_WINNER` (-1): a tie, or, with a single human, a round the human lost (a bot ahead of or level with them). |
| `world.players[i]` | That round's own `score`, `distance`, `fuel` and `alive`; they stay until the next round starts. |
| `wins[i]`, `losses(i)` | Rounds won; rounds finished and not won (with a single human, the rounds lost). |
| `totals[i]`, `distances[i]` | Points and distance over the finished rounds (the last one included), bots too. |
| `round_winners` | Each finished round's winner, in order. `rounds_played()` is its size. |
| `winner` | The match's winner once `MATCH_OVER`, or `NO_WINNER`: with a single human, the human lost the match (2 rounds not won); with several, a draw (level on wins, points and distance after 5 rounds). |
| `phase_ticks` | Steps since the phase began. |
| `human_seats()`, `human_confirmed(bytes)` | The human seats; whether a byte array holds a human seat's confirm press. |
| `to_array()`, `Match.from_array(cfg, a)`, `checksum()`, `clone()` | As World's, the world included. |

**Between rounds.** The match waits in `ROUND_OVER` until a human seat's byte has the confirm bit (pad A or Start),
and counts it only from `Config.MATCH_CONFIRM_TICKS` (60) steps after the round ended: on a pad, A
both shifts gear and confirms, so presses made while racing must not skip the results. Show "press A" once
`phase_ticks >= Config.MATCH_CONFIRM_TICKS`. Bot seats never confirm, and neither does 0xFF: if every human's pad is
gone, the match waits until one is back. The confirm press starts the next round on that step (`world.start_round()`).
Because the flow runs on input bytes, a whole match replays from (seed, seats, humans, bytes), over the network too.

**At the end** (`MATCH_OVER`) the match ignores input: B2 reads the presses itself, for a rematch (a new `Match` with
`app.next_seed()`) or the title.

**The rules as built:**
- Several humans: the first to `MATCH_WINS` (2) round wins takes the match. Otherwise, after `MATCH_ROUNDS_MAX` (5)
  rounds: the most wins, then the most points over the match (`totals`), then the most distance (`distances`); level
  on all three, nobody wins it.
- A single human: the match ends at the human's 2 wins (`winner` is the human) or at `MATCH_LONE_LOSSES` (2) rounds
  not won (`winner` is `NO_WINNER`), so after 2 or 3 rounds.
- A round nobody won counts for nobody: no win, one more round played (and, with a single human, a loss).
- Each round starts afresh (part 1's `start_round()`, plus every bot's `reset()`); the world RNG, the seats' streams
  and the bots' streams go on.

#### The bots (`bot.gd`)

**The hook.** In versus, `World._bot_byte(car)` returns `bots[car.slot].next_byte(cfg, car, players, traffic,
camera_y + anchor, stage_ticks)`: once per running step for each live seat whose byte is 0xFF, in seat order, before
anything moves (part 1's hook contract). Every seat has a bot, so a human seat whose pad goes away is driven by the
same bot and stays human. Single player keeps A1's behaviour: no bots, and a 0xFF seat gets no input.

**What a bot does each step**, all from the world before the step:
1. **Prediction.** It knows the 12 bytes it has decided and not yet sent (`pending`) and works out where they will
   put the car sideways (`ahead_of_time()`: `Car.step_lateral()`'s rules at the car's speed now). It plans from there.
2. **What it sees.** Traffic whose rear edge is below the top of the screen and whose front edge is ahead of the
   car's rear edge, except cars that already bumped this seat and oil this seat already drove over. An object that is
   changing lane takes up its own span and its target lane's.
3. **Gear** (plan §7). High gear when the speed is at least `BOT_HIGH_GEAR_KMH` (160 km/h) and the gap from the car's
   front edge to the first obstacle in its own path is at least `bot_free_ahead` (150 px); otherwise low gear. Fuel
   cars are not obstacles.
4. **Lane** (plan §7). Of the predicted lane and its neighbours, each lane is as clear as the gap to its first
   obstacle, at most `bot_look_ahead` (168 px). A truck counts `bot_truck_caution` (168 px) nearer than it is, so a
   lane with a truck in view ranks below every lane without one. Another live player's car ahead of this one, or level
   with it and of a lower seat, counts `bot_player_ease` (96 px) further than it is, so the car behind gives way. The
   target lane is a fuel car's, if one is within `bot_fuel_reach` (160 px) in one of those lanes with no truck before
   it; otherwise the clearest lane, when it is `bot_lane_margin` (24 px) clearer than the lane it is heading for. Two
   neighbours equally clear: the bot's own RNG picks one.
5. **Steering.** Into the slide while the predicted skid lasts; otherwise toward the target lane's centre, within half
   a step of steering.
6. **Throttle** always; never the brake.
7. **Reaction** (plan §7). The decision joins the end of `pending`; the byte sent is the oldest, decided
   `BOT_REACTION_TICKS` (12) steps before. A round starts with 12 `Bot.START_BYTE` (throttle, low gear, no steering).

**State** (`World.to_array()`'s last entry, one per seat): `rng` (seeded `World.bot_seed(game_seed, slot)` =
`seat_seed(game_seed, slot + BOT_STREAM_SLOT_OFFSET)`, slots 6 to 11, so (slot + 7) x 2^28 draws from the world's
stream and apart from the seats' streams), `pending` (12 bytes), `lane` (the target, -1 for none) and `last_tick` (the
round's running step it last drove). `reset()`, at each round's start: `pending` back to `START_BYTE`, `lane` and
`last_tick` -1; the stream goes on. A bot that did not drive the round's previous step (a human seat whose pad has just
gone away) first takes the car over: `pending` becomes the throttle with the car's present gear and no steering.

**Randomness.** A bot draws only to break a tie between two lanes, from its own stream, so bots never move the world
RNG and the traffic does not depend on how many there are (`test_traffic_does_not_depend_on_the_number_of_bots`).
Nothing is drawn while paused: the world does not ask a bot then (`test_bots_never_draw_while_paused`).

**Cost.** About 13 µs a decision; a 6-bot versus step takes about 240 µs (a 6-seat step without bots, 40 µs).

**Config values.** Constants: `BOT_HIGH_GEAR_KMH` 160 and `BOT_REACTION_TICKS` 12 (the plan's), `BOT_STREAM_SLOT_OFFSET`
6. Standard-profile fields (0 in the phaser profile): `bot_free_ahead` 150 (the plan's), and bot.gd's own
`bot_look_ahead` 168, `bot_truck_caution` 168, `bot_player_ease` 96, `bot_lane_margin` 24, `bot_fuel_reach` 160,
`bot_side_margin` 2. Match constants: `MATCH_WINS` 2, `MATCH_ROUNDS_MAX` 5, `MATCH_LONE_LOSSES` 2,
`MATCH_CONFIRM_TICKS` 60.

#### The versus golden checksum (plan §8 B1)

`tests/test_versus_golden.gd::test_six_seats_7200_ticks_match_the_golden_checksum`. The scenario, through **Match**
(`run_scenario()` in that file):
- `Match.create(Config.standard(), 20261017, 6, 0b000101)`: seats 0 and 2 human, seats 1, 3, 4 and 5 bots; 7200 steps.
- Every seat's byte is 0xFF on every step, so bot.gd drives every car, the human seats included (as after a
  disconnect). Two exceptions, both on seat 0: a pause press (`PAUSE | STEER_NONE`) on steps 1800 and 1860 (pause,
  then resume), and a confirm press (`CONFIRM | STEER_NONE`) on every step that begins with the match in `ROUND_OVER`
  (so each round starts 60 steps after the last one ended).
- The checksum is `Match.checksum()` after step 7200: the match, its world, the seats, the traffic and the bots.
- What it plays: round 1 (seat 2 wins it; three bots go out on the way; five fuel cars taken) and part of round 2.
  The test runs it twice and compares both with the file; it also checks that a round ended, the next started, the
  pause lasted 60 steps, bots went out and fuel cars were taken, so the scenario cannot shrink unnoticed.
- The file is the 64 hex digits and a newline: `8281604f11bec1a2b115d25886c467d0bc0ba8a40f3f169abd5b6def91280cf0`.

**Regenerating it.** Any change to the rules, the bots, the traffic or the layout of `to_array()` changes the checksum,
on purpose or not. After a deliberate change, and only then:
`$GODOT --headless --path . -s res://tools/versus_golden.gd` (it imports nothing, so run `tools/test.sh` or `--import`
first). It plays the scenario twice, writes the file only if both runs agree, and prints the old and the new checksum;
say why in the commit.

#### Bot statistics (`tools/bot_stats.gd`, for B3)

`$GODOT --headless --path . -s res://tools/bot_stats.gd [-- --seeds=20 --first-seed=1 --ticks=18000 --seats=6
--humans=0b111111 --rounds --set=FIELD=VALUE]`. Each seed plays one match for up to 18 000 steps, every seat 0xFF; while
the match is between rounds the lowest human seat confirms; a seed stops when its match is decided. `--set` tries
another value of a standard-profile field (`--set=bot_truck_caution=48`). It prints a line per seed and the summary
below. No assertion: B3 owns the thresholds.

With the defaults (20 seeds from 1, 6 seats all human, every seat driven by bot.gd, up to 18 000 steps; 65 s to run):

| Measure | Value | B3's target (plan §8) |
|---|---|---|
| First elimination, first round of each seed | median **62.3 s** (31.3 to 82.8; quartiles 57.9 to 72.3; 20 rounds) | 45 to 180 s |
| First elimination, every round | median 62.5 s (15.9 to 88.0; quartiles 54.1 to 71.9; 64 rounds) | |
| Leader changes | **2.89 a minute** over 66.2 running minutes; per round median 2.4 (quartiles 1.1 to 4.1; 0 to 9.7) | at least 1 a minute |
| How rounds end | 68 seats out in the 64 rounds' last steps: 20 by a truck, 48 with an empty tank (18 of those touching the bottom edge); 2 rounds with several out at once | |
| Round winners | 64 rounds won, all by human seats (every seat is human here), none without a winner | |
| Matches | 17 of 20 decided within 18 000 steps, each with a winner, in 2 to 5 rounds (median 3); the other 3 stood at 1-1-1-1 after 4 rounds | |
| Bottom edge, overlap | cars touch the bottom edge 11.4 % of their time; two live cars overlap 10.0 % of the time | |
| Per car and minute | 0.32 fuel cars, 0.08 roadside crashes, 6.19 bumps, 1.07 oil skids | |

With one human seat (`--humans=1`, the human seat driven by a bot as well, five bots): rounds last longer (median
86.6 s, 28.0 to 113.0), since a bot going out does not end them (127 did); the human seat won 12 of 51 rounds, and all
20 matches were decided (1 won by the human seat). The first elimination of each first round is the same as with six
humans: play is identical until a car first goes out.

**Tuning.** The median is well inside 45 to 180 s, so no difficulty value was changed (`EDGE_FUEL_DRAIN_PER_SEC`,
`VERSUS_SHRINK_TICKS`, `VERSUS_GAP_SHRINK`, `versus_gap_min` stay the plan's starting values). bot.gd's own values were
set by measuring. Its first values, `bot_truck_caution` 48 and no give-way (measured with `--set=bot_truck_caution=48
--set=bot_player_ease=1000`), gave: first rounds median 52.3 s (11.9 to 81.5), every round median 50.3 s (5.2 to 100.0;
lower quartile 26.6 s), 64 seats out by a truck against 27 with an empty tank, 9 rounds with several out at once (bots
driving as one), cars overlapping 21.3 % of the time, 3.22 leader changes a minute. The replays of those deaths showed
the two faults described under deviations below.

#### Checked to fail

Each rule was broken on purpose, one at a time, in a scratch copy of the tree (50 edits of `bot.gd`, `world.gd`,
`match.gd` and `config.gd`, by a script that is not committed), and each broken version failed the tests for that rule:
a round's start byte without the throttle; no throttle at speed; braking when blocked; high gear from 150 km/h; 140 px
free taken as enough; the free road ignoring a car that changes into the lane; oil not counting for the gear; fuel cars
counted as obstacles; lanes two away; no lane margin; a truck caution of 48; ties always to the first lane; steering
against a skid; no prediction of the pending bytes; a reaction of 11 ticks; no reaction delay; no fuel-car chase;
chasing through a truck; chasing at any range; seeing above the screen; cars that already bumped the seat, or oil it
already used, still counted; no give-way; both cars giving way when level; no takeover; a takeover in low gear; a reset
that keeps the pending bytes or reseeds the bot's stream; bots seeded like the seats; start_round() leaving the bots as
they were; single player driving 0xFF seats; the hook passing a screen top 100 px too high (first caught only by the
golden checksum, so `test_bot_sees_only_the_screen_and_what_can_still_touch_it` now checks it through the world too);
the bots left out of to_array() or clone(); 3 wins to take a match; a cap of 6 rounds; points before wins; no distance
tie-break; a single human ending at 3 losses, or never by losses; confirm presses from bot seats, from 0xFF, or before
the delay; totals not added up; a round nobody won giving seat 0 a win; the world not stepped between rounds; a decided
match taking a confirm; round winners left out of to_array(); no cap; start_round() not called.

#### Deviations from the plan, with reasons

- **Bots in versus only.** Single player keeps A1's behaviour (a 0xFF seat gets no input, no bots in the state): the
  single-player game has no bots, it must stay as it is, and its hook also runs on paused steps, where a bot must not.
- **The confirm guard** (`MATCH_CONFIRM_TICKS`, 60 steps) is not in the plan: a pad's A shifts gear and confirms, so a
  press made while racing in the last second of a round would skip its results.
- **After 5 rounds**, the plan decides by wins and then total points; the match adds total distance (as DECISIONES §3
  breaks a points tie), and level on all three nobody wins.
- **A single human's round nobody won is a loss** (`losses()` counts the rounds not won): the human did not beat every
  bot, and bots cannot win it.
- **Bots give way to the car ahead** (`bot_player_ease`). Cars pass through each other, so this is not about contact:
  without it, bots that come to one spot (two bots heading for the same clear lane; cars held on the bottom edge) make
  the same decisions from then on and drive as one car. Seen before the rule: four bots out by trucks in one step, four
  bots running dry together after 100 s.
- **Trucks rank below any bump** (`bot_truck_caution` = `bot_look_ahead`). With a 48 px caution a boxed-in bot ranked
  "truck 150 px ahead" above "car alongside" and drove toward the truck; by the time the margin let it change its mind,
  the 12-step delay left no time. A bump costs a skid and gives 91 steps of invulnerability; a truck ends the round.
- **The reaction delay is a queue of decisions**, and the bot plans from where its queued bytes will take the car.
  Plan §7 says only "a 12-tick delay"; a bot that steered on a 12-step-old view of its own car would swing about 15 px
  past each lane's centre and back.
- **The golden scenario** has two kinds of non-0xFF bytes on seat 0: the confirm presses a match needs to go on, and one
  pause, to cover pausing with bots.
- **Part 1's tests**: `test_versus_six_seats_same_checksum_twice` replaced and `test_traffic_same_for_2_and_6_seats`
  adapted (above, Files).

#### Known gaps

- **Bots never brake** (plan §7). Boxed in (a road edge or a car on one side, a car alongside on the other) they bump
  the car ahead: about 6 bumps per car and minute. A bump only costs a skid, which they correct.
- **Cars overlap** about 10 % of the time two live cars spend together (the same spot about 2 %): the give-way acts only
  when a clearer lane exists. B2 draws them on top of each other.
- **No difficulty value was tuned.** The median first elimination is inside 45 to 180 s with the plan's starting values
  (`EDGE_FUEL_DRAIN_PER_SEC` 2, `VERSUS_SHRINK_TICKS` 1200, `VERSUS_GAP_SHRINK` 0.9, `versus_gap_min` 40), so they are
  unchanged; only bot.gd's own values were set by measuring. Nothing was tried with people.
- **Rounds are short for the difficulty clock**: most end in about a minute, after two or three shrinks of the gaps;
  the 40 px floor (180 s) was never reached in these runs (the longest round lasted 113 s). Rounds end mostly by an
  empty tank (fuel cars come every 4500 px of road, about 20 s at the top speed, for six cars).
- **Matches in 5 minutes**: 17 of the 20 were decided within 18 000 steps; the other 3 stood at 1-1-1-1 after 4 rounds
  and would end in round 5 (seeds 3, 4 and 12).
- **B2:** the screens (results after each round and the match, "press A" after `MATCH_CONFIRM_TICKS`, a "BOT" mark for
  bot-driven seats if wanted); build the game on `Match` rather than on `World.versus()` directly.
- **B3:** scenario (a) of plan §8 (one scripted human and five bots) needs its own driver; `tools/bot_stats.gd` covers
  (b) and can run `--humans=1` for one human seat driven by a bot.

## B2

### Part 1 (agent B2a): the versus flow

The versus mode from the title to the rematch, built on B1's `Match`: the title's mode choice, the join screen (a seat
per pad, the number of bots), the race screen with one input byte per seat, pause and quit, the round-over and
match-over panels with the confirm delay, rematch and back to the join screen, pads that disconnect and come back,
the fullscreen toggle, and a versus leg in `--selftest`. The drawing is a first, legible version: the six colours are
placeholders and the HUD and panels are plain. B2b gives them their final form (see "For B2b").

#### Files

- **New (B2's):**
  - Input: `scripts/input/seats.gd` (the seats, extends `local_input.gd`), `scripts/input/nav.gd` (menu commands).
  - Screens: `scripts/app/join.gd` with `scenes/join.tscn` (`Join`: `Road`, `JoinView`); `scripts/app/versus.gd` with
    `scenes/versus.tscn` (`Versus`: `Road`, `Cars`, `Hud`).
  - View: `scripts/view/player_colours.gd` (the six colours and the recoloured cars, provisional),
    `scripts/view/join_view.gd`, `scripts/view/versus_hud.gd`.
  - Tests (55 new, 283 in all): `tests/test_join_seats.gd` (15: the seats), `tests/test_menu_nav.gd` (4),
    `tests/test_join_screen.gd` (9), `tests/test_race_screen.gd` (13), `tests/test_title_choice.gd` (10: the title,
    fullscreen, single player), `tests/test_seat_colours.gd` (4); `tests/screen_helpers.gd` (helpers for the screen
    tests, not a test file: boot an App, deliver key and pad events as the engine would, let go of them).
- **Files of other agents edited**, each with tests (details under "Edits of other agents' files"):
  `scripts/app/app.gd`, `scripts/app/title.gd`, `scripts/view/title_view.gd`, `scripts/view/view_config.gd`,
  `scripts/view/cars.gd` (A2's); `README.md` (A3's); `docs/screenshots/01-title.png` re-made.
- Nothing under `scripts/sim/` changed.

#### Verify

| Command | Last line | Exit |
|---|---|---|
| `GODOT=/tmp/claude-0/godot/Godot_v4.7.2-stable_linux.x86_64 tools/test.sh` | `283 passed, 0 failed` | 0 |
| The same after `rm -rf .godot` | `283 passed, 0 failed` | 0 |
| `tools/test.sh --only=test_join_seats,test_menu_nav,test_join_screen,test_race_screen,test_title_choice,test_seat_colours` | `55 passed, 0 failed` | 0 |
| `tools/run_tool.sh smoke` | `smoke: PASS` | 0 |
| `tools/run_tool.sh screenshots` | `screenshots: saved 01-title.png, ... in <repo>/docs/screenshots` | 0 |
| `tools/run_tool.sh scalecheck` | `scalecheck: 5 windows passed` | 0 |
| `tools/export_check.sh` | `export_check: PASS` (the pack holds 88 files) | 0 |
| `$GODOT --headless --path . -- --selftest` | `selftest: ok (600 ticks checked, 600 versus ticks checked, 210 frames drawn)` | 0 |
| `tools/test.sh`, `tools/run_tool.sh smoke` and `tools/export_check.sh` in a copy of `git ls-files -co --exclude-standard` | the same | 0 |

- **Single player is unchanged.** The smoke test's output is line for line the same as at 14b30a8 (a pristine
  `git archive` of it, run side by side). The screenshots 02 to 06 are byte for byte the committed ones; only
  `01-title.png` changed: 1 PLAYER (lit) and VERSUS buttons on the road, the note "2 TO 6 CARS, GAMEPADS ONLY" on a
  dark band, the prompt "UP / DOWN CHOOSE ... GO", and the fullscreen keys beside the best score; the controls boxes
  and the car as before. Looked at, also as an enlarged 1:1 crop: sharp text, nothing overlapping. `scalecheck`
  passes in its five windows (the title's car still lands on its atlas frame pixel for pixel). Every A2 test passes
  unchanged.
- **Checked to fail.** 36 mutations, one at a time, with a script that restored each file (checked by MD5): every one
  made at least one of the new tests fail. They covered: an orphan seat's or a bot seat's byte not 0xFF; joins on the
  highest free seat; no minimum bot; seven cars; claims ignoring the GUID or taking the highest orphan seat; no
  reconnect by GUID; a disconnect freeing a seat in a race; `open()` keeping orphan seats; the program's press on slot
  0; presses not kept per seat; the lone person's bot staying; no delay on the match-over keys; a rematch on the same
  seed; Back or Esc not quitting while paused, or B at the match's end going to the title; no pause on focus loss or
  on Esc; no claim; Start ignoring validity; B, Left and Right doing nothing, or counting pads that hold no seat;
  presses on the join screen reaching the race; Alt+Enter not consumed, F11 not recognised; the title keeping the
  seats, ignoring Down or forgetting its choice; no stick hysteresis, key repeats counted; PRESS A shown too early;
  NO PAD never shown; cars not in their seat's colour; a recolour that skips a shade; the self test's versus leg
  without its disconnect.
- **Seen in pictures** (a scratch tool under xvfb, not committed): the title with VERSUS chosen, the join screen
  empty, with people and bots, and full; a race with six cars (four people, two bots), PAUSED, a seat with NO PAD and
  EDGE, ROUND 1 OVER before and after PRESS A, MATCH OVER. They are not in `docs/screenshots/`: the versus pictures
  of plan §8 come with B2b's colours and HUD.

#### How it fits together

- **Inputs.** `App.input` is the active input, `App.solo` (a `LocalInput`: keyboard and every pad, single player and
  the title) or `App.seats` (a `Seats`: the join screen and the races). `show_title()` and `start_game()` make `solo`
  active and the title lets every pad leave its seat (`seats.reset()`); `show_join()` and `start_versus()` make
  `seats` active. Both follow `Input.joy_connection_changed`. The tools and A2's tests still read
  `app.input.pads.devices` and `app.input.held()` in single player.
- **Menu commands.** `App._input()` gives every event to the active input (bytes) and to `App.nav` (menus), after the
  fullscreen keys (which reach neither). A screen takes its commands in `frame()` (`app.nav.take()`); `App._process()`
  drops what is left after the frame, and a screen switch drops them too.
- **Screens and transitions:**

  ```
  Title --VERSUS chosen + confirm (Enter, Space, A, Start), or a click--> Join
  Join --a seated pad's Start, when World.versus_valid() holds--> Versus (App.start_versus(): seats.lock())
  Join --Esc, or a seated pad's Back (Select)--> Title (every pad leaves)
  Versus, paused --a seated pad's Back, or Esc--> Title
  Versus, match over, from MATCH_CONFIRM_TICKS steps --a seated pad's A or Start--> a rematch on the same screen
                                                     --a seated pad's B or Back, or Esc--> Join (same pads, same bots)
  ```

  Within a match the rounds follow each other on the bytes (B1): any person's Start pauses and resumes; after a round,
  a person's A (or Start) from `Config.MATCH_CONFIRM_TICKS` steps on starts the next one.
- **The race screen** (`versus.gd`): `new_match()` makes `Match.create(Config.standard(), app.next_seed(), slots,
  seats.humans_mask())` of the locked line-up; each frame takes the menu commands, then runs the clock's steps with
  `seats.step_bytes(slots)` (it keeps stepping between rounds and after the match, so `phase_ticks` counts), then
  draws. Esc while a round runs and the focus loss latch a pause press of the program (`seats.press()`), which the
  next step carries. A rematch is a new `Match` with the next seed on the same line-up.
- **Bytes.** A person's seat with its pad: `Held.to_byte(Pads.held_of(device), presses)`, the single-player mapping
  (B or up throttle, A high gear and throttle, down brake, D-pad or stick steers; A and Start presses confirm, Start
  pauses). A bot's seat, and a person's seat whose pad has gone: `PlayerInput.BOT`. A slot past the line-up: `NONE`.
  The keyboard drives nothing in versus.

#### The seats (`scripts/input/seats.gd`)

Six seats, 0 to 5; seat s is P(s + 1) and has colour s for good. A seat is `FREE`, `PERSON` or `BOT` (`kind_of()`).

| Call | What it does |
|---|---|
| `join(device)` | Join screen: a pad that holds no seat takes the lowest free seat (or -1). Its GUID is kept. |
| `leave(device)` | Join screen: frees the pad's seat. |
| `set_bots(n)` | Join screen: the players' choice (`wanted_bots`); `bots` is that choice within `min_bots()` (1 with one person, else 0) and `max_bots()` (6 - people). A person joining when every seat is taken pushes a bot out; the choice stays, so the bot comes back when the person leaves, and the bot a lone person gets goes when a second person joins. |
| `bot_seats()`, `next_lineup()`, `can_start()` | Bots take the lowest free seats; the line-up is every person's and bot's seat in seat order; `can_start()` is `World.versus_valid()` for it. |
| `lock()` / `open()` | Fix the line-up for a match (false, and nothing changes, unless `can_start()`) / end it: orphan seats are freed, the pads still here keep their seats, the bots stay chosen. |
| `lineup`, `seat_at(slot)`, `humans_mask()` | World slot -> seat while locked; the human mask by slot for `Match.create()`. Slots are contiguous, seats need not be: people on seats 1 and 3 with one bot make slots 0, 1, 2 = seats 0 (the bot), 1, 3. |
| `step_bytes(slots)`, `seat_byte(seat)` | The bytes above; each seat's pad presses count once. |
| `press(bits)`, `program_slot()` | The program's presses (focus loss, Esc) go to the lowest person's seat that has its pad; if none has, to the lowest person's seat, whose byte is then `NONE` plus the press for that one step instead of 0xFF (a step that pauses moves nothing, so no car goes undriven). |
| `connection_changed(device, connected)` | A pad gone: on the join screen it leaves its seat; in a race its seat is orphaned at once (0xFF from the next step, the seat stays a person's). A pad connected in a race takes back the lowest orphan seat whose pad had its GUID. |
| `claim(device)` | In a race, A on a pad that holds no seat: the lowest orphan seat whose GUID matches, or else the lowest orphan seat. |
| `seat_of(device)`, `has_pad(seat)`, `is_orphan(seat)`, `people()`, `cars()` | Queries. |
| `guid_of` | `device -> GUID`: `Seats.engine_guid()` (`Input.get_joy_guid()` for a pad in `Input.get_connected_joypads()`, "" otherwise: the engine logs an error for a device it does not know). Tests set a fake. "" never matches. |
| `handle_event()`, `take_presses()`, `clear_presses()`, `held()` | As `LocalInput`'s, per seat: only a seated pad's button events latch presses. |

#### Menu commands (`scripts/input/nav.gd`)

`Vector2i(device, command)`, the keyboard's device being `Nav.KEYBOARD` (-1). Keys by physical key: Up/W `UP`,
Down/S `DOWN`, Left/A `LEFT`, Right/D `RIGHT`, Enter, keypad Enter and Space `ACCEPT`, Esc `BACK`; no repeats. Pads:
D-pad and left stick directions, A `ACCEPT`, B `BACK`, Start `START`, Back `SELECT`. The stick makes a command when it
crosses 0.5 (`Pads.STICK_THRESHOLD`) and again only after coming back inside 0.3.

#### Fullscreen

F11, or Enter or keypad Enter with Alt, going down (not a repeat), on any screen: `App.toggle_fullscreen()` sets the
window's mode to `MODE_FULLSCREEN`, or back to `MODE_WINDOWED` from either fullscreen mode. The event reaches neither
input nor nav, so Alt+Enter is no confirm press. project.godot's stretch settings keep the whole-number scale. Tests
give the app a stand-in `Window` (`App.fullscreen_window`), since a headless window has no screen. Under xvfb the
real window's DisplayServer mode went to fullscreen (3) on F11 and back on Alt+Enter, and the title stayed; the
window's size did not change there (no window manager), so the fullscreen picture itself was not seen. The title's
best-score band names the keys.

#### The self test's versus leg

`App.selftest_versus_problems()`, run by `--selftest` after A2's checks (so by `tools/export_check.sh` on the pack):
the join screen and the race through the real screens, two synthetic pads (devices 90 and 91, nothing held) and one
bot, `SELFTEST_TICKS` steps on a road kept empty (the rules are the simulation tests' business; an empty road keeps
any `--seed` from ending the round early). It checks the match's seats, a pause and a resume by the program's press,
that the bot drove, that the second pad's disconnect (through the app's handler) hands its seat to its bot without
stopping the round, a replay of the same bytes, a round ended by an empty tank, and the way back to the title. Then
the drawn part: A2's 120 frames of a game, 30 of the join screen with two pads and a bot, 60 of their race. The line
became `selftest: ok (600 ticks checked, 600 versus ticks checked, 210 frames drawn)`; `tools/export_check.sh` checks
only its `selftest: ok` start. The A2 and A3 sections above quote the old line.

#### Edits of other agents' files, with tests

- `scripts/app/app.gd` (A2): `solo`, `seats`, `nav`, `title_choice`, `fullscreen_window`; `show_join()`,
  `start_versus()`, `toggle_fullscreen()`, `toggled_window_mode()`, `is_fullscreen_key()`; `show_title()` and
  `start_game()` choose the input; `_switch_to()` and `_process()` drop menu commands; `_input()` handles the
  fullscreen keys first; connection changes go to both inputs and nav; `boot()` adds the recoloured cars; the self
  test's versus leg and drawn frames (`selftest_versus_problems()`, `SELFTEST_PADS`, `SELFTEST_DISCONNECT_TICK`,
  `SELFTEST_JOIN_FRAMES`, `SELFTEST_VERSUS_FRAMES`). Tests: `tests/test_title_choice.gd`, `test_join_screen.gd`,
  `test_race_screen.gd` (`test_the_self_tests_versus_leg_passes`); every test of `tests/test_app.gd` passes
  unchanged.
- `scripts/app/title.gd` (A2): the two choices (`CHOICE_SINGLE`, `CHOICE_VERSUS`), Up and Down from `nav`, confirm from
  `app.input` as before, a click on either button, the remembered choice. Tests: `tests/test_title_choice.gd`; A2's
  `test_a_confirm_press_on_the_title_starts_a_game`, `test_a_click_on_start_starts_a_game` and
  `test_pad_events_drive_the_game` pass unchanged (1 PLAYER is the default choice, and `START_BUTTON` is its button).
- `scripts/view/title_view.gd` and `scripts/view/view_config.gd` (A2): `TITLE_CHOICES`, `START_BUTTON` (moved: now the
  1 PLAYER button), `VERSUS_BUTTON`, `VERSUS_NOTE` on a dark band (`note_band()`), the prompt's text, `FULLSCREEN_HINT`
  on the best-score band, `choice_buttons()`, `set_choice()`. Tests:
  `tests/test_title_choice.gd::test_the_two_buttons_fit_between_the_title_and_the_car`, A2's view tests (the prompt
  fits the screen, the car stays clear of `START_BUTTON`, text sizes), `scalecheck`, and the 01 screenshot looked at.
- `scripts/view/cars.gd` (A2): `seat_colours` (slot -> seat, empty in single player) and `seat_car_sprite()`, which
  is `player_sprite()` in single player. Tests: `tests/test_seat_colours.gd`; the screenshots 02 to 06 unchanged.
- `README.md` (A3): State, Run (the fullscreen keys), Controls (the title, 1 PLAYER, VERSUS), the `--selftest`
  line, Layout (with B1's `match` and `bot`, which it lacked). The Rules section still describes single player only:
  the versus rules are B1's to add.

#### Deviations from the plan and the lead's design, with reasons

- **World slots are not seats.** A seat keeps its colour; the match's world gets slots 0, 1, ... for the seats with a
  car, in seat order (`Seats.lineup`), and the view maps slots to seats. Without it, a seat left free between two
  people (B on the join screen) would either force bots into the gap or change somebody's colour.
- **The bot count keeps the players' choice** and uses it within the rules' bounds, so the bot forced on a lone person
  goes away when a second person joins instead of staying as if chosen.
- **A pad that disconnects on the join screen leaves its seat**, and back on the join screen after a match the orphan
  seats are freed: there is no car to drive there, and a reserved seat nobody holds would only be confusing.
- **The keyboard in versus**: Esc goes back on the join screen and at the match's end, quits while paused (the lead's
  design) and pauses a running round (a press of the program, like the focus loss); nothing else. Versus is pads
  only for driving, and Esc is the PC's pause key.
- **The match-over keys wait `MATCH_CONFIRM_TICKS` steps**, like the round's confirm: A is held for high gear while
  racing, so a press in a race's last second would skip the panel. Start also plays the rematch (it confirms
  elsewhere).
- **The program's press on an orphan seat** (all people's pads gone) is a `NONE` byte with the press for one step
  instead of 0xFF, so the focus loss can still pause.
- **A new input file, `nav.gd`**, not in plan §2: menus need per-device presses the byte does not carry (B, Back, the
  D-pad as presses) and the keyboard's arrows as presses.
- **The self test** gained a versus leg and 90 drawn frames, and its line changed (above).
- **The title**: the START button became the 1 PLAYER button (same constant), the prompt names both choices, a note
  under VERSUS, the fullscreen keys on the best-score band; the app remembers the last choice.
- **Distances in the round panel** are whole px of world (the rules define no unit for players).
- **A rematch keeps the line-up even with a pad gone**: the seat stays a person's and its bot drives until the pad, or
  another one with A, takes it.

#### Known gaps

- **No physical pad** was used: joins, presses, held controls, disconnects and reconnects were driven with synthetic
  `InputEvent`s and `Input.joy_connection_changed.emit()`, GUIDs by a fake source. `Input.get_joy_guid()` of real pads
  is untried. With XInput on Windows every Xbox pad may report the same GUID; pads that share a GUID come back in seat
  order, whichever is which.
- **Fullscreen** was not seen on a real desktop (above).
- **The colours are placeholders**: RED is car_red itself, PURPLE, PINK, TEAL, WHITE, BLACK. WHITE (#d9d6d2) is close
  to the white the truck's container and every sprite's details use (#f0eeec); BLACK (#3a3a40) is close to the
  traffic's dark grey (#383838) and hard to see on the road. Nothing measures their distance yet.
- **The HUD and panels are plain**: a seat panel uses a third of a side panel, mostly empty at the bottom; no event
  messages (PASS +50, OIL...) per seat in versus; the round panel's table is small type.
- **No versus smoke scenario** (B3's) and no versus pictures in `docs/screenshots/` (B2b's, plan §8).
- A pad pressing A to claim an orphan seat does not also confirm (its first press only claims).
- When every person's pad is gone, a paused round stays paused until a pad takes a seat (0xFF never resumes), and the
  results wait (B1: 0xFF never confirms); Esc still quits while paused.

#### For B2b

- **Colours**: change `PlayerColours.SHADES` (body, dark, light per seat, replacing car_red's #ae2633, #611732,
  #f26864) and `NAMES`; everything else follows (`colour()`, `text_colour()`, `add_frames()`, which recolours
  `car_red`, `car_red_ccw45` and `car_red_cw45` at boot into frames named by `frame_name()`). Traffic colours to keep
  away from (the atlas, besides the black outline and the window greys): yellow car #f1bb3b, #e86c18; salmon car
  #d4705c, #844239, #efb681; blue car #1f95e1, #264fa4, #6de0e5; truck #42ad37, #206348, #b4e357, #f0eeec, #a69f96,
  #383838; the fuel car (police sprite, always tinted by the rainbow) is the declared exception. Plan §8 wants
  `test_colour_sets_disjoint` and a pixel-sampling check of the six cars on a versus screenshot.
- **HUD** (`versus_hud.gd`): the pure parts are tested and can stay: `seat_panel_rect()`, `seat_info()`, `mark_of()`,
  `overlay_for()`, `round_lines()`, `match_lines()`, `row()`; the drawing is `draw_seat_panel()`, `draw_bar()`,
  `draw_panel()`. Text sizes must be `ViewConfig.TEXT_SIZES` (`tests/test_view.gd`); keep string literals that look
  like frame names out of `scripts/view/` unless they are atlas frames (`tests/test_assets.gd`).
- **Join view** (`join_view.gd`): `card_rect()`, `draw_card()`, `state_text()`, `status_text()`.
- **Pictures**: the versus shots of plan §8 (join screen, six cars, the six-seat HUD, a round's end). A versus leg
  for `tools/screenshots.gd` must leave 01 to 06 as they are; `tools/tool_base.gd`'s `pad_tap()` and
  `pad_button()` drive the join screen as a player would (A per pad, D-pad right for bots, Start).

#### Requests for B1

None: B2 needed nothing new from the simulation. The self test's versus leg keeps the road empty by clearing
`world.traffic` before each step from `scripts/app` (it checks the screens, not the rules). What B2 relies on, so that
B1's review fixes keep it:

- `Match`: `create()`, `step()`, `phase`, `phase_ticks` (counting in `MATCH_OVER` too: the match-over keys wait on
  it), `round_number`, `wins`, `totals`, `winner`, `last_round_winner()`, `human_seats()`, `world`;
  `Config.MATCH_CONFIRM_TICKS`, `Config.VERSUS_SEATS_MAX`.
- `World`: a human seat's byte other than 0xFF pauses a running round and that step moves nothing (the program's
  press on an orphan seat; `tests/test_join_seats.gd::test_a_press_on_an_orphan_seat_pauses_without_moving`); `Car`
  fields `human`, `alive`, `score`, `distance`, `fuel`, `touching_edge`, `slot`.
- If B1's review changes any of these, the tests above say where.
