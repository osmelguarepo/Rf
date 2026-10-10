# ROAD FIGHTER (MVP)

A driving survival game inspired by Konami's *Road Fighter* (NES, 1985). This MVP covers gameplay and mechanics only: rectangle cars, no art, no sound.

Working title. "Road Fighter" is a Konami trademark, so rename `GAME_TITLE` in `src/config.ts` before any store release.

## Run

```bash
npm install
npm run dev        # http://localhost:5173
```

## Test and build

```bash
npm test           # unit tests (vitest): rules, traffic, skids, fuel, loop, no-audio check
npm run typecheck  # tsc --noEmit (strict)
npm run build      # production build into dist/ (relative paths, opens from file:// too)
npm run e2e        # Playwright smoke tests in headless Chromium, desktop and phone viewports
```

`npm run e2e` uses the pre-installed Chromium at `/opt/pw-browsers/chromium-1194` when it exists, and Playwright's own browser otherwise.

## Controls

| Action | Keyboard | Gamepad (standard mapping) |
|---|---|---|
| Accelerate | Up / W | D-pad up, left stick up |
| Brake | Down / S | D-pad down, left stick down |
| Steer | Left / Right, A / D | D-pad left / right, left stick |
| High gear (up to 400 km/h) | X | A |
| Low gear (up to 198 km/h) | Z | B |
| Start / confirm | Enter / Space | Start or A |
| Pause | Esc / P | Start |

Losing window focus pauses the game automatically.

## Rules

- **Fuel**: 100 units, drains 1 per second while moving. Empty means game over. Rainbow fuel cars refill 20 units and pay a chain bonus (300, 600, 1 200 … up to 10 000). A crash resets the chain.
- **Crashes**: hitting a car costs 5–6 fuel, drops speed to 30 %, and gives 1.5 s of invulnerability. A car can only hit you once per overlap.
- **Oil**: driving onto an oil patch starts a skid. Steering into the slide recovers it. Left alone, the car slides into the roadside and spins out (a crash).
- **Trucks**: contact destroys the car. Game over.
- **Scoring**: +50 per passed car, fuel-car chain bonus, +30 per whole fuel unit left when a stage clears.
- **Stages**: stage 1 is 12 000 px long. Each stage adds 4 000 px, more traffic and 5 % faster traffic.

Design choices where the original sources disagree are listed in `docs/PLAN.md` (section 10).

## Layout

```
src/
  main.ts           Phaser config (360×640, FIT, audio disabled)
  config.ts         Every tunable number
  input.ts          Keyboard and gamepad → GameInput
  session.ts        High score for this page load
  game/             Pure rules, no Phaser imports
    state.ts        GameState and step(); composes everything else
    car.ts          Speed, gears, steering, skid, crash
    traffic.ts      Spawning, relative motion, lane changes, passing
    fuel.ts         Tank, drain, pickups, chain bonus
    stage.ts        Goal distance and stage-clear bonus
    loop.ts         Fixed-timestep accumulator
    edges.ts        Keeps one-shot presses until a step consumes them
    rng.ts          Seeded RNG (reproducible runs)
    collision.ts    Rectangle overlap
  scenes/
    TitleScene.ts   Controls and start
    GameScene.ts    Game loop, HUD, overlays
  render/draw.ts    Rectangle drawing
tests/              Unit tests for src/game and the no-audio check
e2e/                Playwright smoke tests
docs/PLAN.md        Research, framework decision, spec, review outcomes
```

## Next steps (not in this MVP)

- Steam: wrap `dist/` in Electron (Phaser has an official guide) and add Steamworks via `steamworks.js`.
- Konami Man cameo, the other NES courses, and real sprites.
- Mobile touch controls.
