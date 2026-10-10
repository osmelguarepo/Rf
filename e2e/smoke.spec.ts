import { expect, test, type Page } from '@playwright/test';

interface Snapshot {
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
async function snapshot(page: Page): Promise<Snapshot> {
  return page.evaluate(() => (window as unknown as { __roadFighter: { snapshot: () => Snapshot } }).__roadFighter.snapshot());
}

async function startGame(page: Page): Promise<void> {
  await page.goto('/');
  await expect(page.locator('canvas')).toBeVisible();
  // Title scene has no hook yet. The hook appears once the game scene is created.
  await page.keyboard.press('Enter');
  await expect
    .poll(() => page.evaluate(() => Boolean((window as unknown as { __roadFighter?: unknown }).__roadFighter)))
    .toBe(true);
  await expect.poll(async () => (await snapshot(page)).phase).toBe('running');
}

test.describe('Road Fighter MVP smoke', () => {
  let errors: string[];

  test.beforeEach(({ page }) => {
    errors = [];
    page.on('pageerror', (err) => errors.push(`pageerror: ${err.message}`));
    page.on('console', (msg) => {
      if (msg.type() === 'error') errors.push(`console: ${msg.text()}`);
    });
  });

  test.afterEach(() => {
    expect(errors, 'no runtime errors').toEqual([]);
  });

  test('title screen renders without scrolling', async ({ page }, testInfo) => {
    await page.goto('/');
    await expect(page.locator('canvas')).toBeVisible();

    const scrolls = await page.evaluate(() => ({
      x: document.documentElement.scrollWidth > window.innerWidth,
      y: document.documentElement.scrollHeight > window.innerHeight,
    }));
    expect(scrolls).toEqual({ x: false, y: false });

    await testInfo.attach('title', { body: await page.screenshot(), contentType: 'image/png' });
  });

  test('Enter starts a running game and the car drives', async ({ page }, testInfo) => {
    await startGame(page);

    const before = await snapshot(page);
    await page.keyboard.down('ArrowUp');
    await expect.poll(async () => (await snapshot(page)).speed).toBeGreaterThan(50);
    await page.waitForTimeout(1000);
    await page.keyboard.up('ArrowUp');

    const after = await snapshot(page);
    expect(after.distance).toBeGreaterThan(before.distance);
    expect(after.fuel).toBeLessThan(before.fuel);
    expect(after.traffic).toBeGreaterThanOrEqual(0);

    await testInfo.attach('game', { body: await page.screenshot(), contentType: 'image/png' });
  });

  test('steering moves the car while driving', async ({ page }) => {
    await startGame(page);

    await page.keyboard.down('ArrowUp');
    await expect.poll(async () => (await snapshot(page)).speed).toBeGreaterThan(40);
    const startX = (await snapshot(page)).carX;
    await page.keyboard.down('ArrowLeft');
    await page.waitForTimeout(400);
    await page.keyboard.up('ArrowLeft');
    await page.keyboard.up('ArrowUp');

    expect((await snapshot(page)).carX).toBeLessThan(startX);
  });

  test('holding X selects high gear, releasing returns to low gear', async ({ page }) => {
    await startGame(page);

    await page.keyboard.down('KeyX');
    await expect.poll(async () => (await snapshot(page)).gear).toBe('high');
    await page.keyboard.up('KeyX');
    await expect.poll(async () => (await snapshot(page)).gear).toBe('low');
  });

  test('a stubbed gamepad can start the game and drive', async ({ page }) => {
    await page.addInitScript(() => {
      const buttons = Array.from({ length: 17 }, () => ({ pressed: false, value: 0, touched: false }));
      const pad = { id: 'fake pad', index: 0, connected: true, mapping: 'standard', axes: [0, 0, 0, 0], buttons, timestamp: 0 };
      (window as unknown as { __pad: typeof pad }).__pad = pad;
      navigator.getGamepads = () => [pad as unknown as Gamepad];
    });
    await page.goto('/');
    await expect(page.locator('canvas')).toBeVisible();

    // Hold Start until the game scene exists, so the press cannot be missed between frames.
    await page.evaluate(() => {
      (window as unknown as { __pad: { buttons: { pressed: boolean }[] } }).__pad.buttons[9].pressed = true;
    });
    await expect
      .poll(() => page.evaluate(() => Boolean((window as unknown as { __roadFighter?: unknown }).__roadFighter)))
      .toBe(true);
    await page.evaluate(() => {
      (window as unknown as { __pad: { buttons: { pressed: boolean }[] } }).__pad.buttons[9].pressed = false;
    });
    await expect.poll(async () => (await snapshot(page)).phase).toBe('running');

    // Hold B (throttle) on the pad and check the car moves.
    await page.evaluate(() => {
      (window as unknown as { __pad: { buttons: { pressed: boolean }[] } }).__pad.buttons[1].pressed = true;
    });
    await expect.poll(async () => (await snapshot(page)).speed).toBeGreaterThan(40);
    await page.evaluate(() => {
      (window as unknown as { __pad: { buttons: { pressed: boolean }[] } }).__pad.buttons[1].pressed = false;
    });
  });

  test('no Web Audio context is created at runtime', async ({ page }) => {
    await page.addInitScript(() => {
      const counter = window as unknown as { __audioContexts: number };
      counter.__audioContexts = 0;
      for (const name of ['AudioContext', 'webkitAudioContext'] as const) {
        const Original = (window as unknown as Record<string, unknown>)[name] as typeof AudioContext | undefined;
        if (!Original) continue;
        (window as unknown as Record<string, unknown>)[name] = new Proxy(Original, {
          construct(target, args: unknown[]) {
            counter.__audioContexts += 1;
            return Reflect.construct(target, args);
          },
        });
      }
    });
    await startGame(page);
    await page.keyboard.down('ArrowUp');
    await page.waitForTimeout(500);
    await page.keyboard.up('ArrowUp');

    const created = await page.evaluate(() => (window as unknown as { __audioContexts: number }).__audioContexts);
    expect(created).toBe(0);
  });

  test('losing window focus pauses the run', async ({ page }) => {
    await startGame(page);
    await page.evaluate(() => window.dispatchEvent(new Event('blur')));
    await expect.poll(async () => (await snapshot(page)).phase).toBe('paused');
  });

  test('Escape pauses the game and freezes it, Escape resumes', async ({ page }) => {
    await startGame(page);

    await page.keyboard.down('ArrowUp');
    await expect.poll(async () => (await snapshot(page)).speed).toBeGreaterThan(20);
    await page.keyboard.up('ArrowUp');

    await page.keyboard.press('Escape');
    await expect.poll(async () => (await snapshot(page)).phase).toBe('paused');
    const frozen = (await snapshot(page)).distance;
    await page.waitForTimeout(500);
    expect((await snapshot(page)).distance).toBe(frozen);

    await page.keyboard.press('Escape');
    await expect.poll(async () => (await snapshot(page)).phase).toBe('running');
  });
});
