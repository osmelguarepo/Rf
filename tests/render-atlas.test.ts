import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { PLAYER, SPRITE, TRAFFIC } from '../src/config';
import { PIXEL_ART, parsePixelGrid } from '../src/render/pixelArt';
import { decodePng, pngSize } from '../e2e/png';

/**
 * Render-side checks on the shipped art, run without a browser: the atlas is sound for nearest-neighbour drawing and
 * tiling, every frame name the renderer asks for exists, the sprites drawn in code are valid, scales are whole numbers,
 * sprites fit their hitboxes, the pixel font ships with its licence, and asset paths in the code exist.
 */
const ROOT = fileURLToPath(new URL('..', import.meta.url));
const PUBLIC = join(ROOT, 'public');
const ASSETS = join(PUBLIC, 'assets');

interface Frame {
  x: number;
  y: number;
  w: number;
  h: number;
}

const frames = JSON.parse(readFileSync(join(ASSETS, 'sprites.json'), 'utf8')) as Record<string, Frame>;
const atlasFile = readFileSync(join(ASSETS, 'sprites.png'));
const atlas = decodePng(atlasFile);
const entries = Object.entries(frames);

function alphaAt(x: number, y: number): number {
  return atlas.data[(y * atlas.width + x) * 4 + 3];
}

function pixelAt(x: number, y: number): string {
  const i = (y * atlas.width + x) * 4;
  return Array.from(atlas.data.subarray(i, i + 4)).join(',');
}

/** Every pixel of a frame, as [x, y] in atlas coordinates. */
function framePixels(f: Frame): [number, number][] {
  const out: [number, number][] = [];
  for (let y = f.y; y < f.y + f.h; y++) for (let x = f.x; x < f.x + f.w; x++) out.push([x, y]);
  return out;
}

describe('sprite atlas, as the renderer draws it', () => {
  it('has frames', () => {
    expect(entries.length).toBeGreaterThan(0);
  });

  it('keeps every frame inside the PNG size read from its header', () => {
    const { width, height } = pngSize(atlasFile);
    const outside = entries.filter(([, f]) => {
      const values = [f.x, f.y, f.w, f.h];
      if (!values.every((v) => Number.isInteger(v))) return true;
      return f.w <= 0 || f.h <= 0 || f.x < 0 || f.y < 0 || f.x + f.w > width || f.y + f.h > height;
    });
    expect(outside.map(([name, f]) => `${name} ${JSON.stringify(f)} in ${width}x${height}`)).toEqual([]);
  });

  it('has no overlapping frames', () => {
    const overlaps: string[] = [];
    entries.forEach(([a, fa], i) => {
      for (const [b, fb] of entries.slice(i + 1)) {
        const apart = fa.x + fa.w <= fb.x || fb.x + fb.w <= fa.x || fa.y + fa.h <= fb.y || fb.y + fb.h <= fa.y;
        if (!apart) overlaps.push(`${a} / ${b}`);
      }
    });
    expect(overlaps).toEqual([]);
  });

  it('has at least one visible pixel in every frame', () => {
    const empty = entries.filter(([, f]) => framePixels(f).every(([x, y]) => alphaAt(x, y) === 0));
    expect(empty.map(([name]) => name)).toEqual([]);
  });

  it('uses only fully opaque or fully transparent pixels, so edges stay hard when scaled', () => {
    const soft = entries.filter(([, f]) => framePixels(f).some(([x, y]) => alphaAt(x, y) !== 0 && alphaAt(x, y) !== 255));
    expect(soft.map(([name]) => name)).toEqual([]);
  });

  it('makes every *_tile frame fully opaque, so tiled road, verge and grass show no holes', () => {
    const tiles = entries.filter(([name]) => name.endsWith('_tile'));
    expect(tiles.length).toBeGreaterThan(0);
    const holes = tiles.filter(([, f]) => framePixels(f).some(([x, y]) => alphaAt(x, y) !== 255));
    expect(holes.map(([name]) => name)).toEqual([]);
  });

  it('surrounds every frame with a ring that is transparent or repeats its own edge, so neighbours cannot bleed in', () => {
    // A sample that lands one texel outside a frame (rounding at a scrolled or scaled edge) must not pick up a
    // neighbouring sprite. Extruded tile edges are fine: they repeat the frame's own border pixel.
    const bleeding: string[] = [];
    for (const [name, f] of entries) {
      for (let y = f.y - 1; y <= f.y + f.h; y++) {
        for (let x = f.x - 1; x <= f.x + f.w; x++) {
          const inside = x >= f.x && x < f.x + f.w && y >= f.y && y < f.y + f.h;
          if (inside || x < 0 || y < 0 || x >= atlas.width || y >= atlas.height || alphaAt(x, y) === 0) continue;
          const edgeX = Math.min(Math.max(x, f.x), f.x + f.w - 1);
          const edgeY = Math.min(Math.max(y, f.y), f.y + f.h - 1);
          if (pixelAt(x, y) !== pixelAt(edgeX, edgeY)) bleeding.push(`${name} at ${x},${y}`);
        }
      }
    }
    expect(bleeding).toEqual([]);
  });
});

// ---------------------------------------------------------------------------------------------------------------
// Frame names used by the renderer: strings in the SPRITE export of src/config.ts, plus frame-like string literals
// in src/render/*.ts and src/scenes/*.ts (read with a regex). Each must be an atlas frame or a sprite that
// src/render/pixelArt.ts draws in code (the documented fallback).

const FRAME_NAMES = new Set(Object.keys(frames));
const CODE_DRAWN = new Set(Object.keys(PIXEL_ART));
const KNOWN_NAMES = new Set([...FRAME_NAMES, ...CODE_DRAWN]);
/** First word of every frame name ("car", "road", "hud", ...). A string starting with one of these names a frame. */
const FRAME_PREFIXES = new Set([...KNOWN_NAMES].map((name) => name.split('_')[0]));
/** Keys in SPRITE whose string values are not frame names (texture keys, files, fonts). */
const NOT_FRAME_KEY = /^(key|atlas|atlasKey|texture|textureKey|image|json|png|url|path|file|font|fontFamily|family)$/i;

/**
 * Does this string look like a frame name? Known names always count; otherwise snake_case starting with a frame
 * prefix, so 'car_yelow' counts (and fails) but a texture key such as 'sprites' or a font name does not.
 */
function looksLikeFrame(value: string): boolean {
  if (KNOWN_NAMES.has(value)) return true;
  if (!/^[a-z][a-z0-9]*(_[a-z0-9]+)+$/.test(value)) return false;
  return FRAME_PREFIXES.has(value.split('_')[0]);
}

/** Every value in SPRITE under a `frame` key, or that looks like a frame name, with where it was found. */
function namesFromSpriteConfig(): { name: string; where: string }[] {
  const found: { name: string; where: string }[] = [];
  const walk = (value: unknown, path: string, key: string): void => {
    if (typeof value === 'string') {
      if (!NOT_FRAME_KEY.test(key) && (/frame/i.test(key) || looksLikeFrame(value))) found.push({ name: value, where: path });
    } else if (Array.isArray(value)) {
      value.forEach((item, i) => walk(item, `${path}[${i}]`, key));
    } else if (value !== null && typeof value === 'object') {
      for (const [k, v] of Object.entries(value)) walk(v, `${path}.${k}`, k);
    }
  };
  walk(SPRITE, 'SPRITE', 'SPRITE');
  return found;
}

function listFiles(dir: string): string[] {
  if (!existsSync(dir)) return [];
  return readdirSync(dir).flatMap((name: string) => {
    const path = join(dir, name);
    return statSync(path).isDirectory() ? listFiles(path) : [path];
  });
}

function repoPath(path: string): string {
  return relative(ROOT, path).split(sep).join('/');
}

/**
 * Frame-like string literals in src/render/*.ts and src/scenes/*.ts. `${...}` parts of template literals become
 * patterns such as `hud_digit_*`.
 */
function namesFromSource(): { names: { name: string; where: string }[]; patterns: { pattern: string; where: string }[] } {
  const names: { name: string; where: string }[] = [];
  const patterns: { pattern: string; where: string }[] = [];
  const files = [...listFiles(join(ROOT, 'src', 'render')), ...listFiles(join(ROOT, 'src', 'scenes'))];
  for (const file of files.filter((f) => f.endsWith('.ts'))) {
    const text = readFileSync(file, 'utf8');
    for (const match of text.matchAll(/(['"])([a-z][a-z0-9_]*)\1/g)) {
      if (looksLikeFrame(match[2])) names.push({ name: match[2], where: repoPath(file) });
    }
    for (const match of text.matchAll(/`([a-z][a-z0-9_]*_)\$\{[^}`]*\}([a-z0-9_]*)`/g)) {
      if (FRAME_PREFIXES.has(match[1].split('_')[0])) patterns.push({ pattern: `${match[1]}*${match[2]}`, where: repoPath(file) });
    }
  }
  return { names, patterns };
}

describe('frames the renderer uses', () => {
  const fromSource = namesFromSource();
  const used = [...namesFromSpriteConfig(), ...fromSource.names];
  const NONE_FOUND =
    'No frame names found: SPRITE in src/config.ts names no frame, and neither do src/render/*.ts and ' +
    'src/scenes/*.ts. Skipped until the sprite renderer lands.';

  it('exist in sprites.json or are drawn in code by src/render/pixelArt.ts', (ctx) => {
    if (used.length === 0) ctx.skip(NONE_FOUND);
    const missing = used.filter(({ name }) => !KNOWN_NAMES.has(name));
    expect(missing.map(({ name, where }) => `${name} (${where})`)).toEqual([]);
  });

  it('built with a template literal match at least one frame', (ctx) => {
    if (fromSource.patterns.length === 0) ctx.skip('No frame names are built with template literals in src/render or src/scenes.');
    const unmatched = fromSource.patterns.filter(({ pattern }) => {
      const [head, tail] = pattern.split('*');
      return ![...KNOWN_NAMES].some((name) => name.startsWith(head) && name.endsWith(tail) && name.length > head.length + tail.length);
    });
    expect(unmatched.map(({ pattern, where }) => `${pattern} (${where})`)).toEqual([]);
  });
});

// ---------------------------------------------------------------------------------------------------------------

describe('sprites drawn in code (src/render/pixelArt.ts)', () => {
  const sheetColours = new Set<number>();
  for (let i = 0; i < atlas.data.length; i += 4) {
    if (atlas.data[i + 3] > 0) sheetColours.add((atlas.data[i] << 16) | (atlas.data[i + 1] << 8) | atlas.data[i + 2]);
  }

  it('do not reuse a frame name from the atlas', () => {
    expect([...CODE_DRAWN].filter((name) => FRAME_NAMES.has(name))).toEqual([]);
  });

  it('are rectangular grids that use only colours from the sheet', () => {
    const problems: string[] = [];
    for (const [name, rows] of Object.entries(PIXEL_ART)) {
      try {
        const art = parsePixelGrid(rows);
        const foreign = new Set(art.pixels.filter((c): c is number => c !== null && !sheetColours.has(c)));
        if (foreign.size > 0) problems.push(`${name} uses ${[...foreign].map((c) => `#${c.toString(16).padStart(6, '0')}`).join(', ')}`);
      } catch (error) {
        problems.push(`${name}: ${(error as Error).message}`);
      }
    }
    expect(problems).toEqual([]);
  });
});

// ---------------------------------------------------------------------------------------------------------------

describe('sprite scales and sizes in SPRITE', () => {
  /** Width and height of a frame, from the atlas or from its pixel grid. */
  function frameSize(name: string): { w: number; h: number } | undefined {
    const frame = frames[name];
    if (frame) return { w: frame.w, h: frame.h };
    const rows = PIXEL_ART[name];
    return rows ? { w: rows[0]?.length ?? 0, h: rows.length } : undefined;
  }

  it('uses whole-number scales only, so pixels stay square and crisp', () => {
    const bad: string[] = [];
    const walk = (value: unknown, path: string, key: string): void => {
      if (typeof value === 'number' && /scale/i.test(key) && !(Number.isInteger(value) && value >= 1)) bad.push(`${path} = ${value}`);
      else if (value !== null && typeof value === 'object') for (const [k, v] of Object.entries(value)) walk(v, `${path}.${k}`, k);
    };
    walk(SPRITE, 'SPRITE', 'SPRITE');
    expect(bad).toEqual([]);
  });

  it('draws each upright car, the truck and the oil inside its hitbox, filling at least three quarters of it', () => {
    // Hitboxes as src/game/traffic.ts sizes them: trucks and oil have their own, every other kind is a car.
    const hitboxes: [string, { frame: string; scale: number; shadow: number }, { width: number; height: number }][] = [
      ['player', SPRITE.player, PLAYER],
      ...Object.entries(SPRITE.traffic).map(
        ([kind, sprite]) =>
          [`traffic.${kind}`, sprite, kind === 'truck' ? TRAFFIC.truck : kind === 'oil' ? TRAFFIC.oil : TRAFFIC.car] as [
            string,
            { frame: string; scale: number; shadow: number },
            { width: number; height: number },
          ],
      ),
    ];
    const problems: string[] = [];
    for (const [name, sprite, hitbox] of hitboxes) {
      const size = frameSize(sprite.frame);
      if (!size) {
        problems.push(`${name}: no frame ${sprite.frame}`);
        continue;
      }
      // The shadow column and row sit outside the body and are not part of the footprint.
      const w = (size.w - sprite.shadow) * sprite.scale;
      const h = (size.h - sprite.shadow) * sprite.scale;
      const fits = w <= hitbox.width && h <= hitbox.height;
      const fills = w * h >= 0.75 * hitbox.width * hitbox.height;
      if (!fits || !fills) problems.push(`${name}: body ${w}x${h} for hitbox ${hitbox.width}x${hitbox.height}`);
    }
    expect(problems).toEqual([]);
  });
});

// ---------------------------------------------------------------------------------------------------------------

describe('pixel font', () => {
  const fontDir = join(ASSETS, 'font');
  const woff2 = listFiles(fontDir).filter((file) => file.endsWith('.woff2'));

  it('ships the Press Start 2P WOFF2 file under public/assets/font/', () => {
    expect(woff2.map(repoPath)).toContain('public/assets/font/press-start-2p-latin-400-normal.woff2');
    // A real WOFF2 file, not an HTML error page saved under the font's name.
    for (const file of woff2) expect(readFileSync(file).toString('latin1', 0, 4), `${repoPath(file)} signature`).toBe('wOF2');
  });

  it('ships the OFL licence text next to the font', () => {
    const ofl = join(fontDir, 'OFL.txt');
    expect(existsSync(ofl)).toBe(true);
    const text = readFileSync(ofl, 'utf8');
    expect(text).toContain('SIL OPEN FONT LICENSE Version 1.1');
    expect(text).toContain('Press Start 2P');
  });
});

describe('asset paths in the code', () => {
  // Paths such as 'assets/sprites.png' or url(./assets/font/x.woff2) in src/ and index.html, served from public/.
  const files = [...listFiles(join(ROOT, 'src')), join(ROOT, 'index.html')];
  const referenced = files.flatMap((file) =>
    [...readFileSync(file, 'utf8').matchAll(/(?<=["'`(}])(?:\.?\/)?(assets\/[\w./-]+?\.(?:png|json|woff2?|ttf|otf))(?=["'`)?#])/g)].map(
      (match) => ({ path: match[1], where: repoPath(file) }),
    ),
  );

  it('point at files that exist under public/', (ctx) => {
    if (referenced.length === 0) ctx.skip('src/ and index.html reference no files under assets/ yet.');
    const missing = referenced.filter(({ path }) => !existsSync(join(PUBLIC, path)));
    expect(missing.map(({ path, where }) => `${path} (${where})`)).toEqual([]);
  });
});
