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
