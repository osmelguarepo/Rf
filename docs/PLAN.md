# Road Fighter-style MVP — Plan (final, after review)

Working title: **ROAD FIGHTER** (one constant, `GAME_TITLE` in `src/config.ts`). "Road Fighter" is a Konami trademark. Rename before any store release.

This document describes what is implemented. Section 11 records how each review finding was handled.

## 1. Research summary

Sources: StrategyWiki and the Cutting Room Floor were partly blocked (403, DNS). Figures come from search summaries, Wikipedia, and the Arcade-History and Konami wiki entries.

- Konami, arcade Nov/Dec 1984. NES/Famicom Japan 11 Jul 1985, Europe 1992, never North America. The NES version is a survival game with no rival ranking and fewer courses.
- Player car: red Corvette C4 (a rectangle in this MVP).
- Buttons: B accelerates (held), A raises speed to about 400 km/h (held). Sources disagree on exact top speeds (about 196–224 km/h low gear).
- Fuel: about 100 seconds of driving per tank. Rainbow fuel cars refill a small amount and pay points. The NES value is 1000 points (flat).
- Hitting another car sends the car into a spin, as an oil patch does. The car does not explode. A correction is to steer into the slide. A late correction spins the car into the roadside, which costs about 5–6 fuel units.
- Traffic: yellow cars drive straight in large numbers. Red cars change lane once to get in the way. Blue cars change lane more. Trucks destroy the car on contact (one source).
- Scoring: 50 points per passed car. Unused fuel converts to points at stage end (30 per unit, one source).
- There is no timer in the NES game. A stage ends when you reach the goal. Running out of fuel ends the run.
- Konami Man appears as a roadside cameo on clean runs. Out of MVP scope.

## 2. Framework decision

**Phaser 4.2.1 + TypeScript + Vite**, shipped to the web directly and to Steam later through an Electron wrapper.

| Criterion | Phaser 4 + TS + Vite | Godot 4.7 | Unity |
|---|---|---|---|
| Web build | Static `dist/`, no export step | Web export is Compatibility renderer only, about 24 MB empty export, Safari issues | WebGL build, large downloads |
| Steam | Electron wrapper. Phaser has an official guide (Mar 2025). Desktop Heroes shipped on Steam with Phaser + Electron (Oct 2025) | Native desktop export, GodotSteam GDExtension | Native, Steamworks plugin |
| Verifiable here | Yes: `tsc`, `vitest`, `vite build`, Playwright headless | Godot has `--headless`, `--export-release` and GUT or gdUnit4 for CI. The sandbox has no binary and no export templates (about 1 GB) | Editor-centric, hard to verify headless |
| Fit for a rectangle arcade game | Excellent | Excellent | Overkill |

Revisit only if launch needs the Steam overlay, Steam Input, achievements, a small install size, Steam Deck Verified status, or consoles.

**Electron costs (phase 2, not in MVP):** the runtime is about 283 MB unpacked against a 1.4 MB game. steamworks.js 0.4.0 has had no release since August 2024, so evaluate `steamworks-ffi-node` 0.11.3 as well. The Steam overlay needs `electronEnableSteamOverlay()`. Phase 2 also needs an `app://` protocol, Steamworks calls in the main process over IPC, and `Menu.setApplicationMenu(null)`.

The rules layer (`src/game`) has no engine imports, so it runs unchanged in Node, tests and Electron.

## 3. MVP scope

**In scope**
1. Two scenes: **Title** (controls and START) and **Game** (road, traffic, HUD, overlays).
2. Player car (red rectangle): held throttle, held high gear, braking, steering, speed-dependent steering, skids.
3. Fuel: constant drain while running, refills from fuel cars, empty means game over.
4. Traffic (rectangles): yellow, red, blue, trucks, fuel cars, oil.
5. Contacts: car bump (skid, no penalty), roadside crash (fuel loss, speed loss), truck (game over), oil (skid).
6. Scoring: passed cars, fuel-car pickups, stage-clear fuel bonus, session high score.
7. Stages with goals that loop, and difficulty that rises per stage.
8. Pause (Esc / P / Start), automatic pause when the window loses focus or the tab is hidden.
9. Keyboard and gamepad. Gamepad is read through the DOM Gamepad API.
10. No audio. Phaser's audio is disabled in config (`audio: { noAudio: true }`).

**Out of scope (MVP):** sprites and art, Konami Man, the other NES courses, save data, Steam SDK, Electron packaging, touch controls, fullscreen-filling layout (see §11, deferred items), render interpolation.

## 4. Gameplay specification

All numbers live in `src/config.ts`.

**Playfield.** Logical 360 × 640 px, Phaser `FIT`, centred. Road spans x ∈ [60, 300] in three 80 px lanes. Roadside strips are green rectangles with scrolling trees.

**Speed.** Speeds are km/h (HUD). Scroll and relative motion use px/s = km/h × 1 (see §11).

| | Value |
|---|---|
| Low gear top speed | 198 km/h |
| High gear top speed | 400 km/h |
| Low gear acceleration | 70 km/h/s |
| High gear acceleration | 15 km/h/s below 160 km/h, then 45 km/h/s |
| Brake (Down / S) | 120 km/h/s |
| Coasting (no throttle) | −25 km/h/s |
| Above the gear top speed | falls at 25 km/h/s |

**Gears are held, not toggled.** High gear is active only while X (A) is held. Releasing X returns to low gear. The throttle is Up/W, Z (B) or X (A), so holding X also accelerates.

**Steering.** Lateral speed (px/s) = (170 − 0.1 × km/h) × min(1, km/h / 30). The car cannot steer while stopped. Full steering rate is about 150 px/s at 198 km/h and 130 px/s at 400 km/h.

**Skid (oil).**
- Driving onto an oil patch that has not been used yet starts a skid. Lateral slide speed is 90 px/s, with direction from the RNG. No new skid starts while already skidding.
- While skidding, steering does not move the car. The slide carries it at constant speed.
- Steering into the slide reduces the slide speed by 360 px/s² per second, so it reaches zero in about 15 steps. The skid is then over.
- Steering against the slide, or not steering, leaves the slide unchanged.
- Reaching the roadside while sliding is a roadside crash.

**Car bump (traffic car contact).** No fuel loss and no speed loss. The player starts a skid pushed away from the other car, and gets 1.5 s of invulnerability. Each traffic car can bump the player at most once (`struck` flag). A bumped car stays on the road. Bumps during invulnerability are ignored.

**Roadside crash.** Contact with the roadside (steering into the edge, or sliding into it) is a crash. Fuel −5 or −6 (RNG), speed × 0.3, 1.5 s of invulnerability. The car is held at the edge for rendering.

**Truck contact.** Game over (decision O1). Ignored during invulnerability.

**Priority within one step.** Game over (empty tank or truck) beats stage clear. Stage clear is checked after game over.

**Fuel.**
- Tank 100. Drains 1 unit per second while the run is active, moving or not.
- Fuel car: +10 units (capped at 100), 1000 points, flat (no chain). The car is removed on pickup.
- Each stage starts with a full tank.
- Empty tank is game over.

**Scoring.**
- Passing a traffic car (its top edge passes below the player's bottom edge), once per car: +50. Fuel cars and oil never give pass points.
- Fuel-car pickup: +1000.
- Stage clear: +30 per whole fuel unit left.

**Stages.**
- Goal distance: 24 000, 28 000, 32 000, 36 000 px, then the goal loops back to 24 000 px.
- Spawn gaps (distance between spawns) shrink by 0.9 per stage. Car gaps never go below 200 px. Traffic speed does not scale by stage.
- Stage clear shows the bonus. Enter starts the next stage with a full tank and an empty road.

**Traffic spawning (by road distance, not time).** Spawning is driven by the road scrolled, so density does not depend on speed.
- Car gap: 350 px on average (±0 jitter). Types: yellow 60 %, red 20 %, blue 10 %, truck 10 %.
- Oil patch gap: 4000 ± 1000 px.
- Fuel car gap: 8000 ± 2000 px.
- Cars spawn 60 px above the top edge. A lane that is busy near the top is skipped. If every lane is busy, the spawn is retried on the next step.

| Type | Colour | Size (px) | Behaviour |
|---|---|---|---|
| Yellow | `#f4d03f` | 24 × 40 | Straight, 80–120 km/h |
| Red | `#c0392b` | 24 × 40 | Straight, one lane change at random time, 90–110 km/h |
| Blue | `#2e86de` | 24 × 40 | 2–3 lane changes, heads for the player's lane when close, 100–130 km/h |
| Truck | `#7f8c8d` | 30 × 60 | Straight, 60 km/h, game over on contact |
| Fuel car | cycling hue | 24 × 40 | Straight, 90 km/h, pickup |
| Oil patch | `#1a1a1a` | 40 × 24 | Static on road, triggers skid once |

**Player car.** Rectangle 26 × 44 px in `#e74c3c` with a window rectangle. It blinks during invulnerability.

**Pause.** Esc, P or Start pauses. Losing window focus or hiding the tab pauses. Pausing freezes the state (no fuel drain).

## 5. Controls

| Action | Keyboard | Gamepad (standard mapping) |
|---|---|---|
| Throttle (low gear) | Up / W, or Z (B) | D-pad up, B, or left stick up |
| High gear (held, also throttle) | X (A) | A |
| Brake | Down / S | D-pad down, or left stick down |
| Steer | Left / Right, or A / D | D-pad left / right, or left stick |
| Start / confirm | Enter / Space | Start, or A |
| Pause | Esc / P | Start |

Stick threshold is 0.5. Input is read once per frame in `src/input.ts`, so game logic never reads raw keys or pads.

## 6. Architecture

```
index.html                  Meta viewport, empty favicon, module entry
src/
  main.ts                   Phaser.Game config: 360×640, FIT, audio disabled
  config.ts                 Every tunable number and GAME_TITLE
  input.ts                  Keyboard and gamepad (DOM APIs) → GameInput
  session.ts                High score for the page load
  game/                     PURE rules: no Phaser, DOM, Date.now or Math.random
    types.ts                GameInput (held and edge fields), Gear
    edges.ts                One-shot presses latched until a step consumes them
    loop.ts                 Fixed-step accumulator, 0.1 s clamp, 5-step cap
    rng.ts                  Seeded RNG (mulberry32)
    collision.ts            Rectangle overlap
    car.ts                  Speed, gears, steering, skid, roadside, bump
    traffic.ts              Distance-based spawner, relative motion, lane changes, passing
    fuel.ts                 Tank, drain, pickup, crash cost
    stage.ts                Stage goal (looping) and stage-clear bonus
    state.ts                GameState and step(); phases; events
  scenes/
    TitleScene.ts           Controls, START button, gamepad start
    GameScene.ts            Fixed-step loop, HUD, overlays, focus-loss pause
  render/draw.ts            Rectangle drawing helpers
tests/                      Vitest: rules, loop, edges, traffic, skid, purity, no-audio
e2e/smoke.spec.ts           Playwright (desktop and phone): start, drive, gears, pause, gamepad, no audio
docs/PLAN.md                This file
```

**Determinism.** `step(state, input, dt)` is a fixed 1/60 s step. Edge presses are latched until a step consumes them. The same seed and the same inputs give the same game (tested).

**Pinned versions.** `phaser@4.2.1`, `typescript@5.9.3`, `vite@8.3.4`, `vitest@5.0.3`, `@playwright/test@1.56.1` (Chromium 141, matches the sandbox browser), `@types/node@22.20.5`. Node `>=22.12`. `vite.config.ts` uses `base: './'`, which works under sub-paths and with Electron `loadFile`. Plain browsers block module scripts on `file://` (CORS), so the single-file `file://` case is not supported for the web build.

## 7. Screens

**Title.** Background road, title, a decorative red car, a CONTROLS panel (keyboard and gamepad), a START button, the blinking prompt, and the session best score.

**Game.** Road, traffic and player car. HUD: top band with SCORE, HI and STAGE. Left strip: speed, gear (L/H), goal bar. Right strip: fuel gauge. Centre: short messages (CRASH!, SPIN OUT!, OIL!, FUEL!, PASS +50).

**Overlays.** PAUSED (Esc / P / Start resumes). GAME OVER (score, best, Enter retries, Esc or Start goes to title). STAGE CLEAR (score, next stage, Enter continues).

## 8. Acceptance criteria

1. `npm install && npm run dev` opens the title screen. Enter, Space, A, Start or the START button begins the game.
2. Holding Up, Z or X accelerates. Low gear stops at 198 km/h. Holding X selects high gear, up to 400 km/h, and releasing X returns to low gear. Above the gear top speed the car falls at 25 km/h/s.
3. Steering is zero while stopped and about 150 px/s at 198 km/h. The car is clamped only for rendering. Touching the roadside is a crash.
4. Fuel drains at 1 unit per second while running, moving or stopped. A fuel car adds 10 (capped at 100) and scores 1000.
5. A car bump costs no fuel and no speed. It starts a skid away from the car. The same car bumps at most once.
6. Oil starts a skid. Steering into the slide recovers it in about 15 steps. An uncorrected skid reaches the roadside within 2 s from the centre lane, which is a crash (fuel −5 or −6, speed × 0.3).
7. A truck contact, or fuel at 0, shows GAME OVER with the score.
8. A passed traffic car scores 50, once. Oil and fuel cars score no pass points.
9. Reaching the goal shows STAGE CLEAR with 30 per whole fuel unit. The next stage starts with a full tank, an empty road, a goal of 28 000 px, and shorter spawn gaps.
10. Esc or P pauses and freezes the state. Losing window focus or hiding the tab pauses.
11. A gamepad (standard mapping) can start, throttle and steer (tested with a stubbed `navigator.getGamepads`).
12. No audio: no Web Audio context is created at runtime, and `src/` and `index.html` contain no audio APIs or audio files (tested).
13. `npm test`, `npm run typecheck`, `npm run build` and `npm run e2e` all pass.
14. Layout: no page scroll at 1280×720 and 390×844.

## 9. Work order (status)

1. Scaffold, pinned versions, configs. Done.
2. Pure rules and unit tests. Done.
3. Input, scenes, entry point. Done.
4. Smoke tests, README. Done.
5. Review by three Opus max-effort reviewers. Done (§11).
6. Apply accepted review items (this revision). Done.
7. Commit and push to `feat/road-fighter-mvp`. No PR unless asked.

## 10. Open decisions

- **O1 Truck contact = game over.** The source says contact "instantly destroys" the car. The reviewer argued for a crash instead, since the game has no lives. The literal source reading is kept. Change if you prefer a crash.
- **O2 Car contact = bump (resolved).** No fuel or speed penalty, a skid away from the car, each car once.
- **O3 Gears = held (resolved).** A (X) is held for high gear. B (Z) and Up are throttle.
- **O4 Fuel car = 1000 flat, no chain (resolved).** Chain bonus from the arcade game dropped.
- **O5 Framework = Phaser 4 over Godot 4 (see §2).** Electron costs noted. Revisit for Steam overlay, Steam Input, achievements or Deck Verified.
- **O6 Title = "ROAD FIGHTER" in code.** Rename before store submission.

## 11. Review outcomes

Three Opus 5.5 max-effort reviewers checked the plan in parallel: gameplay fidelity, architecture and delivery, and testability and scope. Each finding is marked **Adopted**, **Partly adopted**, **Deferred** (planned, not in this MVP) or **Rejected** (with the reason).

### 11.1 Gameplay fidelity

| # | Finding | Outcome |
|---|---|---|
| 1 | Car contact should be a bump, not a fuel crash. Start a skid away from the car, no fuel loss. | **Adopted** (§4 bump). The search results describe hitting a car as a spin, not a crash. |
| 2 | Truck should be an immediate crash. Game over only at fuel 0. | **Rejected** for now. The source says the truck destroys the car. Kept as O1. |
| 3 | Replace the skid with a 30 px/s wobble, cumulative 0.10 s correction within 0.70 s. | **Rejected**. The current model follows the sources: a slide, correctable by steering into it, and a late correction spins out. The reviewer's blocker (steering pushing the car into the barrier) is fixed: steering does not move the car during a skid. |
| 4 | Gears should be held throttles: B accelerates, A high gear. Up unbound. | **Adopted, partly.** Gears are held. B and A both accelerate, and Up is kept as an extra throttle so keyboard players are not stuck. |
| 5 | px/s = km/h × 1; steering formula with a standstill cutoff; 25 km/h/s fall above the gear top. | **Adopted**. Not yet playtested. The tuning is a starting point. |
| 6 | Spawn per distance, car gap 350 px with a type mix, oil and fuel gaps, floor on car gaps. Skip spawns when the player is slower than the car. Red cars move toward the player's lane. | **Partly adopted**. Distance spawning, the mix and the gaps are adopted. The skip-when-slower rule is unclear and not implemented. Red cars toward the player's lane is **Deferred**. |
| 7 | Refill to 100 each stage. Drain whenever play runs. Fuel car +10. Goals 24 000–36 000 looping. Gaps shrink per stage, no speed scaling. | **Adopted**. The yellow→blue shift per stage is **Deferred**. |
| 8 | Fuel car = 1000 flat. Drop the chain. | **Adopted**. The NES source gives 1000 for the fuel car. |
| 9 | Roadside contact is a crash, no clamp. | **Partly adopted**. Roadside contact is a crash. The car is still held at the edge for rendering, which is a display choice. |
| 10 | Respawn after a 1.0 s wreck, clear traffic ahead, and 1.5 s blink. | **Rejected** for the MVP. The per-car bump limit and invulnerability cover the repeat-hit problem. |

The reviewer's "no Start button" point was based on the plan text. The START button is in the code (`TitleScene`).

### 11.2 Architecture and delivery

| # | Finding | Outcome |
|---|---|---|
| 1 | Audio: set `noAudio`, a runtime check, and a source check. | **Adopted**. `audio: { noAudio: true }`, a runtime `AudioContext` counter in e2e, and a source check in `tests/no-audio.test.ts` (scans `src/` and `index.html`). |
| 2 | Pin Playwright 1.56.1 (Chromium 141), remove the hard-coded browser path, Vitest include. Add SwiftShader flags and assert WebGL. Test the production build. Stub the gamepad. | **Partly adopted**. Pinned, path removed, Vitest include set, gamepad stub test added. **Rejected**: SwiftShader flags and the WebGL assertion (a 2D canvas game works on the Canvas renderer, so the assertion adds nothing). **Deferred**: running e2e against the production build (e2e uses the dev server). |
| 3 | Clamp the loop, sample input per frame, latch edges, pause on blur and hidden. Interpolate rendering. Store RNG state as uint32. | **Partly adopted**. Clamp, latch and pause are in place, and pause on hidden tabs is added. **Deferred**: render interpolation (small judder on 120/144 Hz screens), and uint32 RNG state (replays are not a requirement yet). |
| 4 | Phaser pitfalls: gamepad plugin, `scene.pause()`, key repeat, scene restart, listener cleanup, `skipLibCheck`, TypeScript 7 errors. | **Adopted, mostly N/A**. Input uses the DOM APIs, not Phaser plugins, so most pitfalls do not apply. Key repeat is filtered. Listeners are removed on shutdown. `skipLibCheck` is set. **Rejected**: TypeScript 7 (5.9.3 is kept as the stable line). |
| 5 | Move the input snapshot into `src/game`. Phase machine and events in `state.ts`. A `src/platform/` layer for Electron. A purity test. | **Adopted**: input type in `src/game/types.ts`, phases and events in `state.ts`, and `tests/purity.test.ts`. **Rejected** for now: `src/platform/`. Nothing uses it yet, so it goes in with the Electron phase. |
| 6 | Use `Scale.EXPAND` so the playfield fills desktop and Steam Deck screens. Put the HUD in side panels. | **Deferred**. This is a presentation change only, since the rules are in fixed 360×640 units. FIT portrait is kept for now. Desktop shows side bars. A follow-up will switch to EXPAND with side-panel HUD. |
| 7 | Keep Phaser. Correct the Godot row. Add Electron costs to O5. | **Adopted** (§2). |
| 8 | `file://` wording; exact pins; `engines`. | **Adopted**. Exact pins and `engines: >=22.12` are in `package.json`. The `file://` limit is in §6. TypeScript stays at 5.9.3. |

### 11.3 Testability and scope (earlier review)

| Finding | Outcome |
|---|---|
| Audio: a real `noAudio` fix and a runtime test. | **Adopted** (see 11.2 #1). |
| Vitest must not pick up e2e specs. | **Adopted**. `test.include` covers `tests/**`. |
| Skid recovery and spin must be deterministic and testable. | **Adopted**, in a different form. Constant slide, correction by steering into it, roadside crash. Tested. |
| Move the loop and edge latch into pure modules, with tests. | **Adopted** (`loop.ts`, `edges.ts`, tests). |
| Auto-pause on blur, hidden tab and gamepad disconnect. | **Partly adopted**. Blur and hidden tab are in. Gamepad disconnect is **Deferred**. |
| Each car crashes the player at most once. | **Adopted** (`struck` flag, tested). |
| Fill the missing numbers (spawn, stage, lane change, start state). | **Adopted**. Numbers are in §4 and `config.ts`. |
| Playwright tests must check real game state, not just that a page loaded. | **Adopted**. A dev-only snapshot hook; tests check phase, distance, fuel, speed, gear, traffic. |

### 11.4 Known gaps carried into the next iteration

- Playtesting. Speed, steering, spawn density and fuel economy are estimates. Stage 1 at low gear needs about 121 s at 198 px/s against 100 s of fuel plus pickups, so it is tight. High gear is much easier. Tune after a playtest.
- EXPAND layout and side-panel HUD (11.2 #6).
- Render interpolation and fixed-refresh judder (11.2 #3).
- Production-build e2e (11.2 #2).
- Red-car lane change toward the player and the per-stage shift to blue (11.1 #6, #7).
