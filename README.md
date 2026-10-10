# ROAD FIGHTER (MVP)

A driving survival game inspired by Konami's *Road Fighter* (NES, 1985). This MVP covers gameplay and mechanics, with pixel-art sprites (GrafxKid's CC0 sheet) and the Press Start 2P font. No sound. Every shipped asset and its licence is listed in `ASSETS.md`.

Working title. "Road Fighter" is a Konami trademark, so rename `GAME_TITLE` in `src/config.ts` before any store release.

## Run

```bash
npm install
npm run dev        # http://localhost:5173
```

## Test and build

```bash
npm test           # unit tests (vitest): rules, traffic, skids, fuel, loop, purity, no-audio check
npm run typecheck  # tsc --noEmit (strict)
npm run build      # production build into dist/ (relative paths, for any sub-path and for Electron loadFile)
npm run e2e        # Playwright smoke tests in headless Chromium, desktop and phone viewports
```

`npm run e2e` uses the browser that `@playwright/test@1.56.1` expects. In the sandbox this is the pre-installed Chromium 141 under `PLAYWRIGHT_BROWSERS_PATH`. Elsewhere, run `npx playwright install chromium` first.

## Controls

| Action | Keyboard | Gamepad (standard mapping) |
|---|---|---|
| Throttle | Up / W, Z (B) | D-pad up, B, left stick up |
| High gear (held, also throttle) | X (A) | A |
| Brake | Down / S | D-pad down, left stick down |
| Steer | Left / Right, A / D | D-pad left / right, left stick |
| Start / confirm | Enter / Space | Start, or A |
| Pause | Esc / P | Start |

Gears are held: high gear (up to 400 km/h) only while X or A is held. Low gear tops out at 198 km/h.
Losing window focus or hiding the tab pauses the game.

## Rules

- **Fuel**: 100 units, drains 1 per second while the run is active, moving or not. A fuel car adds 10 and pays 1000 points. Each stage starts with a full tank.
- **Bumps**: hitting a car costs no fuel. It starts a skid away from the car, and each car can bump you only once.
- **Oil**: driving onto an oil patch starts a skid. Steer into the slide to recover it. Left alone, the car reaches the roadside and crashes.
- **Roadside**: touching the roadside is a crash. It costs 5–6 fuel and slows the car to 30 %.
- **Trucks**: contact destroys the car. Game over.
- **Scoring**: +50 per passed car, +1000 per fuel car, +30 per whole fuel unit when a stage clears.
- **Stages**: the goal is 24 000 px, then 28 000, 32 000, 36 000, and it loops. Each stage has denser traffic.

Design choices where the original sources disagree, and the review outcomes, are listed in `docs/PLAN.md` (sections 10 and 11).

## Layout

```
src/
  main.ts           Phaser config (360×640, FIT, pixelArt, audio disabled)
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
    BootScene.ts    Loads the sprite atlas and the font, then starts Title
    TitleScene.ts   Controls and start
    GameScene.ts    Game loop, HUD, overlays
  render/
    draw.ts         Road, traffic, player and HUD drawing (sprites, or rectangles if the atlas is missing)
    sprites.ts      Atlas frames and SpriteLayer (pooled images drawn in call order)
    pixelArt.ts     Sprites the sheet lacks (truck, oil puddle), drawn as pixel grids
    text.ts         Press Start 2P text styles
public/assets/      Sprite atlas, frame map and font (see ASSETS.md)
tests/              Unit tests for src/game, purity and the no-audio check
e2e/                Playwright smoke tests
docs/PLAN.md        Research, framework decision, spec, review outcomes
```

## Next steps (not in this MVP)

- Steam: wrap `dist/` in Electron (Phaser has an official guide). For Steamworks, evaluate `steamworks-ffi-node` (steamworks.js has had no release since August 2024). See `docs/PLAN.md` §2.
- Konami Man cameo and the other NES courses.
- Mobile touch controls.
