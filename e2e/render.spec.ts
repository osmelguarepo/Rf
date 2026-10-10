import { writeFileSync } from 'node:fs';
import { expect, test, type TestInfo } from '@playwright/test';
import { PLAYER, ROAD, VIEW } from '../src/config';
import {
  ASSET_WARNING,
  canvasRegion,
  region,
  shoot,
  snapshot,
  startGame,
  TITLE_MIN_COLOURS,
  waitForTitle,
  watchNetwork,
  type Shot,
} from './game';
import { blockColours, changedFraction, colours, countColours, dominant, hex, histogram } from './png';

/**
 * Checks that the sprite art loads and shows up on screen (docs/ART_PLAN.md §7). Pixel checks read screenshots taken
 * at device resolution, where nearest-neighbour scaling keeps every colour exact.
 */

/** Saves a screenshot with the test's results (test-results/<test>/<name>.png) for the visual review. */
async function keep(testInfo: TestInfo, name: string, shot: Shot): Promise<void> {
  const path = testInfo.outputPath(`${name}.png`);
  writeFileSync(path, shot.png);
  await testInfo.attach(name, { path, contentType: 'image/png' });
}

/**
 * Phaser draws a texture key it does not know as a black square with pure green lines, and says nothing in the
 * console. Nothing in the atlas is pure green, and tinting cannot make it (the atlas has no pure white).
 */
const MISSING_TEXTURE_GREEN = 0x00ff00;

/** The road between the HUD bar at the top and the player car, inside the barriers. */
function roadStrip(shot: Shot) {
  return region(shot, ROAD.left + 4, 40, ROAD.right - ROAD.left - 8, PLAYER.y - 40 - 40);
}

test.describe('Road Fighter art', () => {
  let problems: string[];

  test.beforeEach(({ page }) => {
    problems = [];
    page.on('pageerror', (err) => problems.push(`pageerror: ${err.message}`));
    page.on('console', (msg) => {
      if (msg.type() === 'error' || ASSET_WARNING.test(msg.text())) problems.push(`console.${msg.type()}: ${msg.text()}`);
    });
  });

  test.afterEach(() => {
    expect(problems, 'no runtime errors or asset warnings').toEqual([]);
  });

  test('loads the atlas and the font with no failed requests or HTTP errors', async ({ page }) => {
    const network = watchNetwork(page);
    await startGame(page);
    await page.keyboard.down('ArrowUp');
    await expect.poll(async () => (await snapshot(page)).speed).toBeGreaterThan(40);
    await page.keyboard.up('ArrowUp');

    expect(network.failures).toEqual([]);
    const paths = network.loaded.map((url) => new URL(url).pathname);
    expect(paths).toContain('/assets/sprites.png');
    expect(paths).toContain('/assets/sprites.json');
    expect(paths.filter((path) => /^\/assets\/font\/.+\.woff2$/.test(path))).not.toEqual([]);
  });

  test('the title screen is drawn, not blank', async ({ page }, testInfo) => {
    await page.goto('/');
    const shot = await waitForTitle(page);
    await keep(testInfo, 'title', shot);
    const counts = histogram(canvasRegion(shot));
    expect(counts.size).toBeGreaterThan(TITLE_MIN_COLOURS);
    expect(counts.get(MISSING_TEXTURE_GREEN) ?? 0, "pixels of Phaser's missing-texture green").toBe(0);
  });

  test('the canvas is scaled with nearest-neighbour filtering (pixelArt)', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('canvas')).toBeVisible();
    // Phaser sets image-rendering on its canvas when antialiasing is off, which pixelArt: true does.
    const rendering = await page.locator('canvas').evaluate((canvas) => getComputedStyle(canvas).imageRendering);
    expect(['pixelated', 'crisp-edges']).toContain(rendering);
  });

  test('the pixel font is loaded once the title shows', async ({ page }) => {
    await page.goto('/');
    await waitForTitle(page);
    const faces = await page.evaluate(() => [...document.fonts].map((face) => `${face.family}: ${face.status}`));
    expect(faces.filter((face) => /press.?start.?2p/i.test(face) && face.endsWith(': loaded')), faces.join(', ')).not.toEqual([]);
  });

  test('the game screen draws road, roadside and HUD, not one flat colour', async ({ page }, testInfo) => {
    await startGame(page);
    const shot = await shoot(page);
    await keep(testInfo, 'game-start', shot);

    const road = roadStrip(shot);
    const left = region(shot, 4, PLAYER.y - 30, ROAD.left - 12, VIEW.height - PLAYER.y + 20);
    const right = region(shot, ROAD.right + 8, PLAYER.y - 30, VIEW.width - ROAD.right - 12, VIEW.height - PLAYER.y + 20);

    const counts = histogram(canvasRegion(shot));
    expect(counts.size, 'colours on the whole canvas').toBeGreaterThan(TITLE_MIN_COLOURS);
    expect(counts.get(MISSING_TEXTURE_GREEN) ?? 0, "pixels of Phaser's missing-texture green").toBe(0);
    expect(histogram(road).size, 'colours on the road (asphalt and markings)').toBeGreaterThan(1);
    const roadColour = hex(dominant(road));
    expect(roadColour, 'the road is drawn').not.toBe('#000000');
    expect(hex(dominant(left)), 'left roadside differs from the road').not.toBe(roadColour);
    expect(hex(dominant(right)), 'right roadside differs from the road').not.toBe(roadColour);
  });

  test('the road scrolls while driving', async ({ page }, testInfo) => {
    await startGame(page);
    await page.keyboard.down('ArrowUp');
    await expect.poll(async () => (await snapshot(page)).speed).toBeGreaterThan(20);
    const before = await snapshot(page);
    const first = roadStrip(await shoot(page));

    let latest: Shot | undefined;
    await expect
      .poll(
        async () => {
          latest = await shoot(page);
          return changedFraction(first, roadStrip(latest));
        },
        { message: 'share of road pixels that changed while driving' },
      )
      .toBeGreaterThan(0);
    const after = await snapshot(page);
    await page.keyboard.up('ArrowUp');

    expect(after.distance).toBeGreaterThan(before.distance);
    // Traffic spawns only after 175 px of road, so nothing but the road itself can have changed the strip.
    expect(after.traffic).toBe(0);
    if (latest) await keep(testInfo, 'driving', latest);
  });

  test('the player car is drawn as a crisp sprite', async ({ page }, testInfo) => {
    await startGame(page);
    const state = await snapshot(page);
    // Spawning follows distance driven, so before the first throttle the player car is alone on the road.
    expect(state.distance).toBe(0);
    expect(state.traffic).toBe(0);
    const shot = await shoot(page);
    await keep(testInfo, 'car', shot);

    // The car's hitbox, and the same road columns 80 px further up as a reference for what bare road looks like.
    const inset = 2;
    const w = PLAYER.width - 2 * inset;
    const h = PLAYER.height - 2 * inset;
    const car = region(shot, state.carX + inset, PLAYER.y + inset, w, h);
    const road = new Set(colours(region(shot, state.carX + inset, PLAYER.y - 80 + inset, w, h)));
    const carPixels = colours(car).filter((colour) => !road.has(colour));

    expect(carPixels.length / (car.width * car.height), 'share of the hitbox covered by something that is not road').toBeGreaterThan(0.4);

    const ranked = [...countColours(carPixels).entries()].sort((a, b) => b[1] - a[1]);
    const summary = ranked.slice(0, 20).map(([colour, n]) => `${hex(colour)}×${n}`).join(' ');
    // Nearest-neighbour scaling copies sprite pixels, so a few colours cover the whole car (all of it, in a
    // simulation of car_red at 3×). Linear filtering or a smoothed canvas blends neighbours into many in-between
    // colours, and the main 16 then cover 77% or less.
    const main = ranked.slice(0, 16).reduce((sum, [, n]) => sum + n, 0);
    expect(main / carPixels.length, `share of car pixels in its 16 main colours: ${summary}`).toBeGreaterThan(0.97);

    // A sprite, not a flat rectangle: every upright car frame in the atlas has five to seven colours that each fill
    // at least 2% of it, while the rectangle car had a body and a window. Counting 2×2 blocks of one colour leaves
    // out the one-pixel lines that edge smoothing adds.
    const blocks = blockColours(car, road);
    const totalBlocks = [...blocks.values()].reduce((sum, n) => sum + n, 0);
    const solid = [...blocks.entries()].filter(([, n]) => n >= totalBlocks * 0.02).map(([colour]) => hex(colour));
    expect(solid.length, `colours filling at least 2% of the car's solid blocks: ${solid.join(' ')}`).toBeGreaterThanOrEqual(4);
  });
});
