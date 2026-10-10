import { expect, type Page } from '@playwright/test';
import { VIEW } from '../src/config';
import { crop, decodePng, histogram, type RgbaImage } from './png';

/** Shared helpers for the Playwright tests: game state, starting a run, screenshots in game coordinates. */

export interface Snapshot {
  phase: 'running' | 'paused' | 'stageClear' | 'gameOver';
  stage: number;
  distance: number;
  score: number;
  fuel: number;
  speed: number;
  carX: number;
  gear: 'low' | 'high';
  traffic: number;
}

/** The game exposes a read-only snapshot in dev mode (see GameScene.create). */
export async function snapshot(page: Page): Promise<Snapshot> {
  return page.evaluate(() => (window as unknown as { __roadFighter: { snapshot: () => Snapshot } }).__roadFighter.snapshot());
}

/** True once the game scene has been created (it installs the snapshot hook). */
export async function inGame(page: Page): Promise<boolean> {
  return page.evaluate(() => Boolean((window as unknown as { __roadFighter?: unknown }).__roadFighter));
}

/**
 * Opens the page and starts a run with Enter. The canvas appears when Phaser boots, a moment before the boot scene
 * starts listening for keys, so a press made that early is lost. Keep pressing until the game scene exists: Enter
 * does nothing during a run, so a spare press is harmless.
 */
export async function startGame(page: Page): Promise<void> {
  await page.goto('/');
  await expect(page.locator('canvas')).toBeVisible();
  await expect
    .poll(async () => {
      if (!(await inGame(page))) await page.keyboard.press('Enter');
      return inGame(page);
    })
    .toBe(true);
  await expect.poll(async () => (await snapshot(page)).phase).toBe('running');
}

/** A decoded screenshot of the viewport, and where the game canvas sits in it. */
export interface Shot {
  png: Buffer;
  image: RgbaImage;
  /** Screenshot pixels per logical game pixel. */
  scale: number;
  /** Screenshot pixel position of the canvas's top-left corner. */
  left: number;
  top: number;
}

/** Takes a screenshot at device resolution (no resampling, so colours are exact) and maps the canvas into it. */
export async function shoot(page: Page): Promise<Shot> {
  const box = await page.locator('canvas').boundingBox();
  if (!box) throw new Error('the game canvas is not on screen');
  const dpr = await page.evaluate(() => window.devicePixelRatio);
  const png = await page.screenshot();
  return { png, image: decodePng(png), scale: (box.width / VIEW.width) * dpr, left: box.x * dpr, top: box.y * dpr };
}

/**
 * Screenshot pixels inside a rectangle given in logical game pixels. The rectangle is shrunk by one screen pixel on
 * each side, so pixels that scaling shares with the neighbouring logical pixel are left out.
 */
export function region(shot: Shot, x: number, y: number, w: number, h: number): RgbaImage {
  const x0 = Math.ceil(shot.left + x * shot.scale) + 1;
  const y0 = Math.ceil(shot.top + y * shot.scale) + 1;
  const x1 = Math.floor(shot.left + (x + w) * shot.scale) - 1;
  const y1 = Math.floor(shot.top + (y + h) * shot.scale) - 1;
  return crop(shot.image, x0, y0, x1 - x0, y1 - y0);
}

/** The whole canvas in a screenshot. */
export function canvasRegion(shot: Shot): RgbaImage {
  return region(shot, 0, 0, VIEW.width, VIEW.height);
}

/** A blank or loading canvas has a colour or two; the title screen (art, panel and text) has far more. */
export const TITLE_MIN_COLOURS = 12;

/** Waits until the canvas shows more than a handful of colours, i.e. the title screen has been drawn. */
export async function waitForTitle(page: Page): Promise<Shot> {
  await expect(page.locator('canvas')).toBeVisible();
  let shot: Shot | undefined;
  await expect
    .poll(
      async () => {
        shot = await shoot(page);
        return histogram(canvasRegion(shot)).size;
      },
      { message: 'distinct colours on the title screen' },
    )
    .toBeGreaterThan(TITLE_MIN_COLOURS);
  if (!shot) throw new Error('no screenshot taken');
  return shot;
}

/**
 * Console messages for a missing frame, a bad atlas file, or an asset or font that failed to load: Phaser's own
 * (node_modules/phaser/src/textures and src/loader) and the game's frame-map loader (src/render/sprites.ts).
 * Chromium's own WebGL warnings are not included.
 */
export const ASSET_WARNING =
  /has no frame|Invalid Texture Atlas|Invalid atlas json|frame already exists|No texture found|Texture key already in use|Font failed to load|Failed to process file|File failed|Sprite atlas:/i;

/**
 * Records failed requests and HTTP errors on the page. A data: URL (the favicon) never reaches the network, so it is
 * skipped. `loaded` lists the URLs that answered with a success status.
 */
export function watchNetwork(page: Page): { failures: string[]; loaded: string[] } {
  const log = { failures: [] as string[], loaded: [] as string[] };
  page.on('requestfailed', (request) => {
    if (request.url().startsWith('data:')) return;
    log.failures.push(`request failed: ${request.url()} (${request.failure()?.errorText ?? 'no reason given'})`);
  });
  page.on('response', (response) => {
    if (response.url().startsWith('data:')) return;
    if (response.status() >= 400) log.failures.push(`HTTP ${response.status()}: ${response.url()}`);
    else log.loaded.push(response.url());
  });
  return log;
}
