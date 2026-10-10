import { inflateSync } from 'node:zlib';

/**
 * A minimal PNG reader and pixel helpers for the render tests, so no image dependency is needed.
 * It handles what the tests meet: Playwright screenshots and the sprite atlas, which are 8-bit,
 * non-interlaced PNGs. Anything else throws.
 */

export interface RgbaImage {
  width: number;
  height: number;
  /** 4 bytes per pixel (R, G, B, A), row by row from the top left. */
  data: Uint8Array;
}

const SIGNATURE = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
/** Samples per pixel for each PNG colour type: grey, RGB, palette, grey + alpha, RGBA. */
const CHANNELS: Readonly<Record<number, number>> = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 };

/** Width and height from the IHDR chunk, which the PNG format requires to come first. */
export function pngSize(png: Uint8Array): { width: number; height: number } {
  const buf = Buffer.from(png.buffer, png.byteOffset, png.byteLength);
  if (!SIGNATURE.every((byte, i) => buf[i] === byte) || buf.toString('ascii', 12, 16) !== 'IHDR') {
    throw new Error('not a PNG file');
  }
  return { width: buf.readUInt32BE(16), height: buf.readUInt32BE(20) };
}

function paeth(a: number, b: number, c: number): number {
  const p = a + b - c;
  const pa = Math.abs(p - a);
  const pb = Math.abs(p - b);
  const pc = Math.abs(p - c);
  return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
}

export function decodePng(png: Uint8Array): RgbaImage {
  const buf = Buffer.from(png.buffer, png.byteOffset, png.byteLength);
  const { width, height } = pngSize(buf);
  const bitDepth = buf[24];
  const colourType = buf[25];
  const interlace = buf[28];
  const channels = CHANNELS[colourType];
  if (bitDepth !== 8 || interlace !== 0 || channels === undefined) {
    throw new Error(`unsupported PNG: bit depth ${bitDepth}, colour type ${colourType}, interlace ${interlace}`);
  }

  let palette: Buffer = Buffer.alloc(0);
  let paletteAlpha: Buffer = Buffer.alloc(0);
  const idat: Buffer[] = [];
  for (let offset = 8; offset + 8 <= buf.length; ) {
    const length = buf.readUInt32BE(offset);
    const type = buf.toString('ascii', offset + 4, offset + 8);
    const body = buf.subarray(offset + 8, offset + 8 + length);
    offset += 12 + length; // length, type, body, CRC
    if (type === 'PLTE') palette = body;
    else if (type === 'tRNS') paletteAlpha = body;
    else if (type === 'IDAT') idat.push(body);
    else if (type === 'IEND') break;
  }

  // Undo the per-row filters. Each row starts with a filter byte; a, b and c are the left, up and up-left bytes.
  const stride = width * channels;
  const raw = inflateSync(Buffer.concat(idat));
  if (raw.length !== height * (stride + 1)) throw new Error('PNG image data has the wrong length');
  const samples = new Uint8Array(height * stride);
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)];
    const src = y * (stride + 1) + 1;
    const row = y * stride;
    for (let i = 0; i < stride; i++) {
      const a = i >= channels ? samples[row + i - channels] : 0;
      const b = y > 0 ? samples[row - stride + i] : 0;
      const c = y > 0 && i >= channels ? samples[row - stride + i - channels] : 0;
      const x = raw[src + i];
      let value: number;
      if (filter === 0) value = x;
      else if (filter === 1) value = x + a;
      else if (filter === 2) value = x + b;
      else if (filter === 3) value = x + ((a + b) >> 1);
      else if (filter === 4) value = x + paeth(a, b, c);
      else throw new Error(`bad PNG filter ${filter} on row ${y}`);
      samples[row + i] = value & 0xff;
    }
  }

  const data = new Uint8Array(width * height * 4);
  for (let p = 0; p < width * height; p++) {
    const s = p * channels;
    let rgba: [number, number, number, number];
    if (colourType === 0) rgba = [samples[s], samples[s], samples[s], 255];
    else if (colourType === 2) rgba = [samples[s], samples[s + 1], samples[s + 2], 255];
    else if (colourType === 3) {
      const index = samples[s];
      rgba = [palette[index * 3] ?? 0, palette[index * 3 + 1] ?? 0, palette[index * 3 + 2] ?? 0, paletteAlpha[index] ?? 255];
    } else if (colourType === 4) rgba = [samples[s], samples[s], samples[s], samples[s + 1]];
    else rgba = [samples[s], samples[s + 1], samples[s + 2], samples[s + 3]];
    data.set(rgba, p * 4);
  }
  return { width, height, data };
}

/** A copy of a rectangle of the image. The rectangle is clamped to the image. */
export function crop(image: RgbaImage, x: number, y: number, w: number, h: number): RgbaImage {
  const x0 = Math.max(0, Math.floor(x));
  const y0 = Math.max(0, Math.floor(y));
  const x1 = Math.min(image.width, Math.floor(x + w));
  const y1 = Math.min(image.height, Math.floor(y + h));
  const width = Math.max(0, x1 - x0);
  const height = Math.max(0, y1 - y0);
  const data = new Uint8Array(width * height * 4);
  for (let row = 0; row < height; row++) {
    const start = ((y0 + row) * image.width + x0) * 4;
    data.set(image.data.subarray(start, start + width * 4), row * width * 4);
  }
  return { width, height, data };
}

/** 0xRRGGBB of each pixel whose alpha is at least `minAlpha` (screenshots are opaque, so all of them). */
export function colours(image: RgbaImage, minAlpha = 1): number[] {
  const out: number[] = [];
  for (let i = 0; i < image.data.length; i += 4) {
    if (image.data[i + 3] >= minAlpha) out.push((image.data[i] << 16) | (image.data[i + 1] << 8) | image.data[i + 2]);
  }
  return out;
}

/** How many times each colour occurs in a list. */
export function countColours(list: readonly number[]): Map<number, number> {
  const counts = new Map<number, number>();
  for (const colour of list) counts.set(colour, (counts.get(colour) ?? 0) + 1);
  return counts;
}

/** How many pixels have each colour. */
export function histogram(image: RgbaImage): Map<number, number> {
  return countColours(colours(image));
}

/**
 * For each colour, how many 2×2 blocks of identical pixels it fills. Colours a filter leaves along an edge form lines
 * one pixel wide and fill no block; a sprite pixel scaled up by nearest-neighbour fills many.
 */
export function blockColours(image: RgbaImage, skip: ReadonlySet<number> = new Set()): Map<number, number> {
  const counts = new Map<number, number>();
  const at = (x: number, y: number): number => {
    const i = (y * image.width + x) * 4;
    return (image.data[i] << 16) | (image.data[i + 1] << 8) | image.data[i + 2];
  };
  for (let y = 0; y + 1 < image.height; y++) {
    for (let x = 0; x + 1 < image.width; x++) {
      const colour = at(x, y);
      if (skip.has(colour)) continue;
      if (at(x + 1, y) === colour && at(x, y + 1) === colour && at(x + 1, y + 1) === colour) {
        counts.set(colour, (counts.get(colour) ?? 0) + 1);
      }
    }
  }
  return counts;
}

/** The colour that covers the most pixels. */
export function dominant(image: RgbaImage): number {
  let best = 0;
  let bestCount = -1;
  for (const [colour, count] of histogram(image)) {
    if (count > bestCount) [best, bestCount] = [colour, count];
  }
  return best;
}

/** Fraction of pixels that differ between two images of the same size. */
export function changedFraction(a: RgbaImage, b: RgbaImage): number {
  if (a.width !== b.width || a.height !== b.height) throw new Error('images differ in size');
  let changed = 0;
  for (let i = 0; i < a.data.length; i += 4) {
    if (a.data[i] !== b.data[i] || a.data[i + 1] !== b.data[i + 1] || a.data[i + 2] !== b.data[i + 2]) changed++;
  }
  return changed / (a.width * a.height || 1);
}

export function hex(colour: number): string {
  return `#${colour.toString(16).padStart(6, '0')}`;
}
