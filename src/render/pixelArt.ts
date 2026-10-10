import type { Textures } from 'phaser';
import { cssColour } from './draw';

/**
 * Sprites the GrafxKid sheet does not have, drawn in code as pixel grids (docs/ART_PLAN.md §2, fallback).
 * This art is the project's own work. Its colours are picked from the sheet, so it matches the sheet's sprites.
 *
 * One character is one texture pixel, and '.' is transparent. SPRITE in src/config.ts sets the scale each
 * texture is drawn at, so that the drawn size equals the object's hitbox.
 */
export const PIXEL_PALETTE: Readonly<Record<string, number>> = {
  k: 0x141414, // black: shadows, oil
  w: 0xf0eeec, // white
  u: 0xa69f96, // light grey
  q: 0x383838, // dark grey
  m: 0x32384a, // windscreen, dark
  n: 0x4f6872, // windscreen, light
  g: 0x42ad37, // green
  G: 0x206348, // dark green
  h: 0xb4e357, // light green
};

/**
 * Box truck seen from above: green cab at the top, white container with ribs behind it.
 * Body 10×20 with a 1 px shadow on the right and bottom, like the sheet's cars. At 3× the body is the 30×60 hitbox.
 */
export const TRUCK: readonly string[] = [
  '..GggggG...',
  '.GwggggwG..',
  '.Ggggggggk.',
  '.Gmmmmmmgk.',
  '.Gmnnnnmgk.',
  '.Ghhhhhhgk.',
  '.Ggggggggk.',
  '..GGGGGGkk.',
  '..qqqqqqk..',
  'quwwwwwwuq.',
  'quwwwwwwuqk',
  'quuuuuuuuqk',
  'quwwwwwwuqk',
  'quwwwwwwuqk',
  'quuuuuuuuqk',
  'quwwwwwwuqk',
  'quwwwwwwuqk',
  'quuuuuuuuqk',
  'quwwwwwwuqk',
  'qqqqqqqqqqk',
  '.kkkkkkkkkk',
];

/**
 * Oil puddle with a shine and a drop, in the style of the sheet's 6×6 oil_spill, which is too small for the
 * 40×24 hitbox. 10×6 at 4× is exactly the hitbox. No shadow: it lies flat on the road.
 */
export const OIL_PUDDLE: readonly string[] = [
  '...kkkk...',
  '.kkwkkkkk.',
  'kkkkkkkkkk',
  'kkkkkkkkkk',
  '.kkkkkkkk.',
  '...kkk...k',
];

/** Texture key → grid. The keys are the frame names SPRITE uses. */
export const PIXEL_ART: Readonly<Record<string, readonly string[]>> = {
  truck: TRUCK,
  oil_puddle: OIL_PUDDLE,
};

export interface PixelImage {
  width: number;
  height: number;
  /** Row-major colours, 0xRRGGBB. null is transparent. */
  pixels: (number | null)[];
}

/** Parses a grid. Ragged rows and unknown characters throw, so a typo fails at boot instead of drawing garbage. */
export function parsePixelGrid(rows: readonly string[], palette: Readonly<Record<string, number>> = PIXEL_PALETTE): PixelImage {
  const height = rows.length;
  const width = rows[0]?.length ?? 0;
  if (width === 0) throw new Error('Pixel grid is empty');

  const pixels: (number | null)[] = [];
  rows.forEach((row, y) => {
    if (row.length !== width) throw new Error(`Pixel grid row ${y} is ${row.length} wide, expected ${width}`);
    for (const char of row) {
      if (char === '.') {
        pixels.push(null);
        continue;
      }
      const colour = palette[char];
      if (colour === undefined) throw new Error(`Pixel grid row ${y} uses '${char}', which is not in the palette`);
      pixels.push(colour);
    }
  });
  return { width, height, pixels };
}

/** Adds each grid in PIXEL_ART as a canvas texture, one texture pixel per character. Keys that exist are left alone. */
export function addPixelArtTextures(textures: Textures.TextureManager): void {
  for (const [key, rows] of Object.entries(PIXEL_ART)) {
    if (textures.exists(key)) continue;
    const art = parsePixelGrid(rows);
    const texture = textures.createCanvas(key, art.width, art.height);
    if (!texture) continue;

    const context = texture.getContext();
    art.pixels.forEach((colour, i) => {
      if (colour === null) return;
      context.fillStyle = cssColour(colour);
      context.fillRect(i % art.width, Math.floor(i / art.width), 1, 1);
    });
    // Uploads the canvas to the GPU texture.
    texture.refresh();
  }
}
