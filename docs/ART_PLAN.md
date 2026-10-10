# Art plan: make the MVP look like the real game

Goal: replace the rectangle visuals with free pixel art in the spirit of the NES *Road Fighter*, without changing the gameplay rules or the tuning in `src/config.ts`.

Supersedes the rectangle-car requirement from the first brief, which the user has now lifted for visuals. Sound is still out of scope (the brief said no sounds), so Freesound is not used.

## 1. Constraints

- Every asset must be free to use, commercially if needed, and its licence must be recorded in the repo.
- Keep the NES look: pixel art, flat colours, small top-down sprites, scaled up with nearest-neighbour filtering. No smooth vector art, no 3D.
- Gameplay stays the same. Collision uses the existing logical rectangles. Sprites are drawn to match those rectangles.
- No audio files, no audio APIs (existing tests enforce this).
- Assets load from the bundle (`public/`), not from a CDN, so the Electron wrapper works later.

## 2. Source audit

| Source | Checked | Licence | Use? | Reason |
|---|---|---|---|---|
| **GrafxKid "TD racing assets"** (OpenGameArt, opengameart.org/content/top-down-arcade-racing-game) | Yes. PNG 832×352 downloads and was viewed. | **CC0**. Author asks for credit ("Credit me as GrafxKid"). | **Yes, primary source** | True pixel art, top-down. Has road and shoulder tiles, grass, several small cars, a fuel gauge and props. Closest match to NES style. |
| **Kenney Racing Pack** (kenney.nl, also on OpenGameArt) | Yes. Zip downloaded and License.txt read. | **CC0**. Credit optional. | **No** | Good CC0 top-down cars and oil, but smooth flat vector style. Mixing that with pixel art would look wrong. |
| Kenney Isometric Road Tiles | Listing read | CC0 | No | Isometric view. |
| **Press Start 2P** font (`@fontsource/press-start-2p` 5.3.0 on npm; Google Fonts) | Yes. npm licence field = OFL-1.1 | **OFL-1.1** | **Yes, for HUD and titles** | Pixel-style font. Shipped as a local package. Its licence text must be kept with the font. |
| game-icons.net | Licence page read | CC BY 3.0 (credit each author) | Not needed for MVP | Could be used later for icons. Attribution is required, which adds work. |
| lospec.com | Reachable | Palettes vary by author | Reference only | Used to check that colours stay in a small palette. Each palette must be checked before use. |
| Mixamo | — | Free, but for 3D characters and animation | No | The game has no 3D characters. |
| Freesound | Blocked from sandbox (403) | Varies | No | No sound in the MVP. |
| itch.io | Not used | Varies per asset | Not in this pass | Would need per-asset checking. Add later only if needed. |

**Primary decision:** GrafxKid's sheet, CC0, with credit given anyway. Credit: "GrafxKid (CC0), OpenGameArt".

**Fallback if a sprite is missing or unusable:** draw the missing sprite in code as an ASCII pixel grid, in the project's own palette. The project owns that art, so the licence is clear.

## 3. Asset pipeline

1. `scripts/fetch-assets.mjs` downloads the GrafxKid PNG from its OpenGameArt URL into `assets/source/`. The script checks the file hash, so a changed download fails loudly.
2. `scripts/slice-sheet.py` (Python with Pillow) slices the sheet into individual sprites, writes `public/assets/sprites.png` (a packed atlas) and `public/assets/sprites.json` (frame name → x, y, w, h). It checks the grid, reports any sprite that does not fit, and never guesses silently.
3. `public/assets/font/` holds the Press Start 2P woff2 and OFL text, copied from the npm package.
4. `ASSETS.md` in the repo root lists every shipped file: source URL, author, licence, and what it is used for. The OFL and CC0 text is included or linked.
5. A test (`tests/assets.test.ts`) fails if a shipped asset is missing from `ASSETS.md`, if the atlas JSON references a frame outside the image, or if an audio file appears anywhere in `public/`.

## 4. Visual mapping (logical units)

Logical playfield stays 360×640. Sprites are drawn at an integer scale (1×, 2× or 3×) so pixels stay crisp under `Phaser.Scale.FIT`. Each sprite's drawn size is chosen so its footprint roughly matches the existing hitbox. Hitboxes do not change.

| Game object | Current hitbox (px) | Sprite | Notes |
|---|---|---|---|
| Player car | 26×44 | Red car, top-down, from the sheet | Blink when invulnerable (keep existing rule). |
| Yellow / red / blue traffic | 24×40 | Matching-colour cars from the sheet | The sheet has several cars. Pick one per colour. |
| Truck | 30×60 | Largest vehicle in the sheet, or a truck built from two cars | Check the sheet. If none exists, use the fallback. |
| Oil patch | 40×24 | Oil or dark-stain sprite | Use a stain sprite if the sheet has one. |
| Fuel car | 24×40 | Rainbow or multi-coloured car | Keep the existing hue cycle as a tint over a white car sprite if needed. |
| Road | 240 px wide, 3 lanes | Asphalt tile strip, scrolled by `distance` | Tile vertically with offset `distance % tileHeight`. Keep the existing lane dash timing. |
| Shoulders and barriers | — | Grass and kerb tiles from the sheet | Keep the 4 px barrier positions. |
| Roadside scenery | — | Trees or bushes from the sheet, scrolled | Same scroll rule as the current trees. |
| HUD | — | Press Start 2P text, sheet's fuel gauge if usable | Text stays in logical space. |

## 5. Code changes

- `src/render/draw.ts` keeps its functions, but they draw sprite frames instead of rectangles. The public signatures stay, so tests keep working.
- `src/scenes/TitleScene.ts` and `GameScene.ts` load the atlas in a new `src/scenes/BootScene.ts`. Boot waits for the atlas and the font (`document.fonts.load`) before starting Title.
- `src/main.ts` sets `pixelArt: true` for nearest-neighbour scaling.
- Game rules (`src/game/`) are untouched. The purity test must still pass.
- `src/config.ts` gets a small `SPRITE` section for scales and frame names.

## 6. Team plan (for the /goal step)

Three Opus 5.5 max-effort agents:

1. **Assets agent.** Writes `scripts/fetch-assets.mjs`, `scripts/slice-sheet.py`, `ASSETS.md`, the font copy, and `tests/assets.test.ts`. Produces `public/assets/sprites.png` and `sprites.json`. Reports which sprites exist, which need the fallback, and the grid it detected. Goes first, because the others depend on its output.
2. **Renderer agent.** Starts after the assets agent finishes. Implements `BootScene`, the sprite-based `draw.ts`, the road tiling, the HUD font, `pixelArt: true`, and the `SPRITE` config. Keeps the existing draw function signatures.
3. **QA agent.** Runs in parallel with the renderer agent, working against the agreed atlas format. Updates the Playwright tests: assert sprites loaded (no failed requests, no 404s), add a screenshot check that the canvas is not blank and the road is not a single colour, and a visual check against the existing screenshots. Also re-checks the no-audio and purity tests.

Each agent reports back with its changed files and test results. The lead then runs `npm test`, `npm run typecheck`, `npm run build` and `npm run e2e`, looks at screenshots, and commits to `feat/road-fighter-mvp`.

## 7. Acceptance criteria

1. `ASSETS.md` lists every shipped file with its source, author, licence and use. All are CC0, OFL-1.1 or the project's own work.
2. No audio files or audio APIs in the repo (existing tests pass).
3. Player, traffic, oil, fuel car, road, shoulders and HUD all show sprites, not rectangles. The one exception is any object that uses the documented fallback.
4. Hitboxes and all gameplay numbers are unchanged. The existing unit tests pass without edits, apart from the render-only tests.
5. Sprites are crisp at the game's FIT scale (nearest-neighbour, integer scale).
6. The asset test fails if a file is added without a licence record.
7. Typecheck, unit tests, build and e2e all pass. Screenshots reviewed by the lead.

## 8. Risks

- **Sprite sheet mismatch.** The sheet may lack a truck or a clean oil sprite. The fallback handles this, and the assets agent must report it.
- **Top-down versus NES view.** The NES game draws cars from behind, not from above. The top-down sheet is the closest free match, and this difference should be stated to the user.
- **Scaling blur.** Non-integer scales blur pixel art. The scale rules above avoid this.
- **Font loading race.** Text created before the font loads shows a fallback font. `BootScene` waits for the font before starting.
- **Download availability.** If OpenGameArt is unreachable from the build environment, the assets agent should say so and use the fallback, not invent files.
