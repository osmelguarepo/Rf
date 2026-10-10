# Road Fighter-style MVP — Implementation Plan

Working title: **ROAD FIGHTER** (kept in one constant, `GAME_TITLE`, so it can be renamed before any store release. "Road Fighter" is a Konami trademark.)

## 1. Research summary

Sources (2 of 3 original StrategyWiki/Cutting Room Floor pages were blocked; figures below come from search summaries and Wikipedia):

- Konami, arcade Nov/Dec 1984. NES/Famicom Japan 11 Jul 1985. The NES port is a simplified survival version: no rival ranking, fewer courses. Europe got it in 1992, never North America.
- Player car: red Corvette C4 (drawn as a rectangle in this MVP).
- Speed buttons: B and A are two gears. Sources disagree on which button does what, and on the top speeds (about 196–224 km/h low, about 400 km/h high).
- Fuel: about 100 seconds of driving per tank. Refilled by touching multicoloured "fuel cars". The bonus climbs with each consecutive catch, from 300 up to 10,000 points (StrategyWiki).
- Crashes: a car crash or an oil-induced spin that ends in the roadside costs about 5–6 fuel units.
- Oil slicks: cause a skid. The correction is to steer in the direction of the skid. Too late and the car spins out.
- Traffic (NES): yellow cars drive straight in large numbers. Red cars change lane once. Blue cars change lane more and try to hit you. Trucks destroy the car on contact.
- Scoring: passing a car is 50 points (one source). Unused fuel is converted to points at the end of each stage (30 per unit, one source).
- Konami Man appears as a roadside cameo on a clean run. Deferred, out of MVP scope.
- Goal per stage: reach the end without running out of time, hitting cars, or running out of fuel.

Conflicting details are resolved by the design choices in §4 and listed as **Open decisions** in §10.

## 2. Framework decision

**Recommendation: Phaser 4 (4.2.1, MIT) + TypeScript + Vite, shipped to the web directly and to Steam via an Electron wrapper.**

| Criterion | Phaser 4 + TS + Vite | Godot 4.7 | Unity |
|---|---|---|---|
| Web build | Native: static `dist/` folder, no export step | Web export uses Compatibility renderer only, about 24 MB empty export, Safari issues | WebGL build, large downloads |
| Steam | Electron wrapper (Phaser has an official March 2025 guide; Desktop Heroes shipped on Steam Oct 2025 with Phaser + Electron) | Native desktop export; GodotSteam GDExtension | Native; Steamworks plugin |
| Verifiable in this sandbox (no GUI editor, Chromium available) | Yes: `tsc`, `vitest`, `vite build`, Playwright screenshots | Editor-only workflow, hard to verify headless | Editor-only, hard to verify headless |
| Fit for a rectangle-based 2D arcade game | Excellent | Excellent | Overkill |

Consequence: keep the game logic free of Phaser imports, so the same code runs in the browser build and in the later Electron wrapper.

## 3. MVP scope

**In scope**
1. Two scenes only:
   - **Title scene**: game title, controls panel (keyboard and gamepad), START prompt (Enter / Space / gamepad Start, or click).
   - **Game scene**: the road and gameplay, with HUD and overlays (pause, game over, stage clear).
2. Player car (red rectangle) with steering, accelerate, brake, two gears (B = low, A = high), speed-dependent steering.
3. Fuel gauge: drains while moving, refilled by fuel cars, empty = game over.
4. Traffic (rectangles): yellow (straight), red (one lane change), blue (multiple lane changes, steers toward the player), truck (instant destruction).
5. Crashes: contact with a car = crash (fuel loss, speed drop, short invulnerability). Oil patch = skid. Uncorrected skid into the barrier = spin-out crash.
6. Scoring: passing cars, fuel-car chain bonus, end-of-stage fuel conversion, high score kept in memory for the session.
7. Stage progress bar. Stage clear, then the next stage with more traffic and higher speed.
8. Pause (Esc / P).
9. Keyboard and gamepad input (Steam players expect gamepads).
10. No audio of any kind. No sound files, no Web Audio, no Phaser sound manager.

**Out of scope (MVP)**: sprites, art, Konami Man cameo, multiple visually distinct courses, real save data, Steam SDK integration (achievements, cloud), Electron packaging (documented as phase 2), mobile touch controls, online features.

## 4. Gameplay specification

All numeric values live in `src/config.ts` as tunable constants. The values below are the starting point.

**Coordinates and display.** Logical canvas 360 × 640 px, `Phaser.Scale.FIT`, centred. Road spans x ∈ [60, 300] (240 px, three lanes of 80 px, centres 100 / 180 / 260). Roadside strips outside the road are drawn as green rectangles.

**Speed model.** Speed is in km/h (shown on HUD). Scroll and relative movement use `px/s = kmh × 0.5`.

| Parameter | Value |
|---|---|
| Low gear (B) top speed | 198 km/h |
| High gear (A) top speed | 400 km/h |
| Accel (low gear) | 70 km/h/s |
| Accel (high gear) | 45 km/h/s (slower from standstill, faster near top) |
| Brake (Down) | 120 km/h/s |
| Coast drag (no input) | 25 km/h/s |
| Gear selection | Sticky. Press A for high, B for low. Default low at start. |

**Steering.** Lateral rate `steerRate = 220 − 0.4 × speed` px/s (about 141 px/s at 198 km/h, 60 px/s at 400 km/h). Car is clamped to the road.

**Skid and spin (oil)** (revised after review, see §11).
- Driving onto an oil patch that has not been used yet starts a skid. Lateral slide speed `slideVx = ±90 px/s`, direction chosen by RNG. No new skid while already skidding.
- While skidding, steering does **not** move the car sideways. The slide carries it at constant speed.
- Steering into the slide reduces `|slideVx|` by 360 px/s² until it reaches 0 (recovered, about 15 steps from 90 px/s).
- Steering against the slide, or not steering, leaves the slide unchanged.
- Reaching the roadside while sliding (car edge ≤ 60 or ≥ 300) = **spin-out crash**. An uncorrected centre-lane slide spins out in about 1.2 s.

**Crash (car contact or spin-out).** Fuel −5 or −6 (integer, RNG). Speed set to 30 %. Chain bonus reset. Skid cleared. Invulnerable 1.5 s (car blinks). Each traffic car can crash the player **at most once** (`struck` flag). The car stays on the road.

**Truck contact.** Instant destruction = **game over** (single life). Ignored during invulnerability, the same as car contact. See open decision O1.

**Priority within one step.** Game over (empty tank or truck) beats stage clear. Stage clear is checked after game over.

**Fuel cars.** Removed on pickup. Give the chain bonus only, never pass points. Missing one does not reset the chain.

**Spawning.** When every lane is blocked near the top of the screen, the spawner retries after 0.1 s instead of skipping the spawn.

**Fuel.** Tank 100 units. Drain 1.0 unit/s while the car is moving (about 100 s of driving). Empty = game over.
- Fuel car pickup: +20 fuel (capped at 100).
- Chain bonus: 300, 600, 1 200, 2 400, 4 800, 9 600, then 10 000 for each further catch. Chain resets on crash.

**Scoring.**
- Passing a traffic car (its top edge passes below the player's bottom edge, counted once): +50.
- Fuel car pickup: chain bonus as above.
- Stage clear: +30 per remaining fuel unit.

**Stages.**
- Stage 1 goal: 12 000 px of road distance (about 120 s at low gear). Each next stage: +4 000 px goal, traffic spawn interval −10 %, base traffic speed +5 %, same visuals.
- Stage clear overlay: shows stage bonus, Enter continues.

**Traffic spawning.** Deterministic RNG (seeded mulberry32, seed configurable so tests are repeatable). Spawn timers per type, no two cars overlapping in the same lane within the spawn zone.

| Type | Colour | Size (px) | Behaviour |
|---|---|---|---|
| Yellow | `#f4d03f` | 24 × 40 | Straight, 80–120 km/h |
| Red | `#c0392b` | 24 × 40 | Straight, one lane change at random y |
| Blue | `#2e86de` | 24 × 40 | 2–3 lane changes, steers toward player when close |
| Truck | `#7f8c8d` | 30 × 60 | Straight, 60 km/h, lethal on contact |
| Fuel car | cycling rainbow tint | 24 × 40 | Straight, 90 km/h, pickup |
| Oil patch | `#1a1a1a` | 40 × 24 | Static on road, triggers skid |

**Player car.** Rectangle 26 × 44 px, red `#e74c3c`, rear window highlight as a smaller rectangle. Blinks during invulnerability.

## 5. Controls

| Action | Keyboard | Gamepad |
|---|---|---|
| Accelerate | Up / W | D-pad Up / left stick Up |
| Brake | Down / S | D-pad Down / left stick Down |
| Steer | Left / Right, A / D | D-pad Left/Right / left stick |
| High gear (A) | X | A button |
| Low gear (B) | Z | B button |
| Start / confirm | Enter / Space | Start / A |
| Pause | Esc / P | Start in game |

Input is abstracted in `src/input.ts` into an `Input` snapshot per frame, so game logic never reads raw keys.

## 6. Architecture

```
index.html
src/
  main.ts                  Phaser.Game config (360x640, FIT), registers scenes
  config.ts                Tunable constants and GAME_TITLE
  input.ts                 Keyboard and gamepad → Input snapshot
  game/                    PURE TypeScript, no Phaser import (unit-testable)
    rng.ts                 mulberry32 seeded RNG
    car.ts                 Speed, gear, steering, skid, spin, invulnerability
    fuel.ts                Tank, drain, refill, crash cost, chain bonus
    traffic.ts             Traffic entities, spawner, lane changes, pass detection
    collision.ts           AABB overlap helper
    stage.ts               Stage index, goal distance, stage-clear bonus, difficulty
    state.ts               GameState + step(input, dt) orchestrating the above
  scenes/
    TitleScene.ts          Controls panel + START
    GameScene.ts           Renders GameState with Graphics rectangles and HUD text
tests/                     vitest unit tests for src/game/*
e2e/smoke.spec.ts          Playwright: title → start → game renders, no console errors
docs/PLAN.md               This file
README.md                  How to run, test, build; controls; design notes
```

**Build and tooling.** `vite` for dev and build (`base: './'` so `dist/` works from `file://` in the later Electron wrapper). TypeScript strict mode. `vitest` for unit tests. Playwright uses the pre-installed Chromium via `executablePath: '/opt/pw-browsers/chromium'` (no browser download).

**Determinism.** `GameState.step` is a pure function of `(state, input, dt)`. Fixed-step update (1/60 s accumulator) so logic does not depend on frame rate.

## 7. Screens

**Title scene**: background road strip, title text, a red rectangle car as decoration, controls table (text), a blinking "PRESS ENTER / START" line, high score for the session.

**Game scene**: road and traffic rectangles. HUD on the right-hand side strip or top: SCORE, HI, STAGE, SPEED (km/h), GEAR (L / H), FUEL gauge (rectangle bar, red under 20 %), stage progress bar.

**Overlays**: PAUSED (Esc / P to resume), GAME OVER (score, Enter = play again, Esc = back to title), STAGE CLEAR (bonus, Enter = next stage).

## 8. Acceptance criteria

1. `npm install && npm run dev` opens the title screen; Enter or click starts the game.
2. Holding Up increases speed up to the gear's top speed; A raises the top speed to 400; B lowers it back to 198.
3. Steering moves the car within the road; steering rate decreases with speed.
4. Fuel drains while moving; fuel cars refill it, with chain bonus 300 → 10 000.
5. Car contact: fuel drops 5–6, speed drops, short invulnerability. No double-hit within the invulnerability window.
6. Oil: skid starts; steering the same way recovers it; not correcting spins the car into the barrier (fuel −5/6).
7. Truck contact or fuel = 0 → game over overlay with score.
8. Passing cars grants +50 once per car.
9. Reaching the stage goal shows STAGE CLEAR with fuel bonus; next stage has more traffic.
10. Pause works (Esc / P), game state frozen.
11. Gamepad (Standard mapping) can drive and start.
12. No audio: `grep` for `Audio`, `sound`, `.mp3`, `.wav`, `.ogg` in `src/` returns nothing.
13. `npm test` (vitest) passes; `npm run typecheck` passes; `npm run build` passes; `npm run e2e` passes (headless Chromium).
14. Layout fits a 16:9 desktop and a 9:16 phone viewport without page scroll.

## 9. Work order

1. Scaffold: package.json, tsconfig, vite, index.html, .gitignore.
2. `src/game/*` pure logic + unit tests (TDD: write tests against the spec first).
3. `src/input.ts`, `src/config.ts`.
4. `TitleScene`, `GameScene`, `main.ts`.
5. Playwright smoke test, README.
6. Verify: typecheck, tests, build, e2e, screenshots reviewed.
7. Leave changes uncommitted in the working tree (no commit or PR unless asked).

## 10. Open decisions (defaults chosen)

- **O1 Truck**: sources say contact destroys the car. Default: **instant game over** (no lives system in the sources). Alternative: treat as a heavy crash.
- **O2 Car contact**: sources are ambiguous whether a car collision ends the run. Default: **crash, not game over** (fuel loss + speed drop).
- **O3 Gears**: sources disagree which button is low or high. Default: **B = low (198 km/h), A = high (400 km/h)**.
- **O4 Pass points**: 50 (NES source). Fuel-car chain as StrategyWiki (300 → 10 000). Fuel conversion 30/unit (one source, low confidence).
- **O5 Framework**: Phaser 4 over Godot 4 (see §2). Revisit only if Steam-native features become a requirement before release.
- **O6 Title**: working title "ROAD FIGHTER" in code. Rename before store submission.
