import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { TRAFFIC, VIEW } from '../src/config';
import { createCar, type CarState } from '../src/game/car';
import type { TrafficCar, TrafficKind } from '../src/game/traffic';
import {
  drawBackdrop,
  drawPlayer,
  drawTraffic,
  playerSprite,
  trafficSprite,
  type FrameStyle,
  type SpriteSpec,
  type SpriteTarget,
} from '../src/render/draw';
import { PIXEL_ART } from '../src/render/pixelArt';

/**
 * Runs the real drawing functions against a target that records what they draw, as a SpriteLayer would draw it,
 * with frame sizes from public/assets/sprites.json and src/render/pixelArt.ts. No browser and no Phaser needed.
 */
const ROOT = fileURLToPath(new URL('..', import.meta.url));
const atlas = JSON.parse(readFileSync(join(ROOT, 'public', 'assets', 'sprites.json'), 'utf8')) as Record<
  string,
  { x: number; y: number; w: number; h: number }
>;

interface DrawnFrame {
  name: string;
  x: number;
  y: number;
  scale: number;
  style?: FrameStyle;
}

interface DrawnRect {
  x: number;
  y: number;
  w: number;
  h: number;
  colour: number;
}

function sizeOf(name: string): { w: number; h: number } | undefined {
  const frame = atlas[name];
  if (frame) return { w: frame.w, h: frame.h };
  const rows = PIXEL_ART[name];
  return rows ? { w: rows[0]?.length ?? 0, h: rows.length } : undefined;
}

class RecordingTarget implements SpriteTarget {
  readonly frames: DrawnFrame[] = [];
  readonly rects: DrawnRect[] = [];

  frameSize(name: string): { w: number; h: number } | undefined {
    return sizeOf(name);
  }

  drawFrame(name: string, x: number, y: number, scale: number, style?: FrameStyle): void {
    this.frames.push({ name, x, y, scale, style });
  }

  drawRect(x: number, y: number, w: number, h: number, colour: number): void {
    this.rects.push({ x, y, w, h, colour });
  }
}

const KINDS: TrafficKind[] = ['yellow', 'red', 'blue', 'truck', 'fuelCar', 'oil'];

function trafficCar(kind: TrafficKind, x: number, y: number): TrafficCar {
  const size = kind === 'truck' ? TRAFFIC.truck : kind === 'oil' ? TRAFFIC.oil : TRAFFIC.car;
  return {
    id: 1,
    kind,
    x,
    y,
    w: size.width,
    h: size.height,
    kmh: 0,
    targetX: null,
    lanesLeft: 0,
    laneTimer: 0,
    passed: false,
    consumed: false,
    struck: false,
  };
}

/** Distances that put the tile rows at different offsets, including fractions and a stage-length run. */
const DISTANCES = [0, 0.5, 1, 7.25, 31, 32, 33, 100, 119.9, 1234.5, 23999.9];

/** The player upright, sliding left and sliding right, at a fractional x as it is while steering. */
const PLAYERS: [string, CarState][] = [
  ['upright', createCar(167.3)],
  ['skidding left', { ...createCar(150.6), slideVx: -90 }],
  ['skidding right', { ...createCar(181.2), slideVx: 90 }],
];

/** Everything one frame of the game draws in the world layer, at a given distance. */
function drawWorld(distance: number): RecordingTarget {
  const target = new RecordingTarget();
  drawBackdrop(target, distance);
  drawTraffic(target, KINDS.map((kind, i) => trafficCar(kind, 70 + (i % 3) * 80 + 0.4, 40 + i * 90 + 0.7)), 1.3);
  for (const [, car] of PLAYERS) drawPlayer(target, car, 0);
  return target;
}

describe('world drawing with sprites', () => {
  const drawn = DISTANCES.map(drawWorld);

  it('asks only for frames that exist in the atlas or are drawn in code', () => {
    const unknown = new Set(drawn.flatMap((t) => t.frames.map((f) => f.name)).filter((name) => !sizeOf(name)));
    expect([...unknown]).toEqual([]);
  });

  it('draws every frame at a whole-number scale', () => {
    const bad = drawn.flatMap((t) => t.frames.filter((f) => !Number.isInteger(f.scale) || f.scale < 1));
    expect(bad.map((f) => `${f.name} at ${f.scale}x`)).toEqual([]);
  });

  it('covers the whole canvas with tiles at every scroll distance, leaving no gaps', () => {
    for (const [i, target] of drawn.entries()) {
      const covered = new Uint8Array(VIEW.width * VIEW.height);
      for (const f of target.frames.filter((frame) => frame.name.endsWith('_tile'))) {
        const size = sizeOf(f.name);
        if (!size) continue;
        const x0 = Math.max(0, Math.round(f.x));
        const y0 = Math.max(0, Math.round(f.y));
        const x1 = Math.min(VIEW.width, Math.round(f.x) + size.w * f.scale);
        const y1 = Math.min(VIEW.height, Math.round(f.y) + size.h * f.scale);
        for (let y = y0; y < y1; y++) covered.fill(1, y * VIEW.width + x0, y * VIEW.width + x1);
      }
      const gap = covered.indexOf(0);
      const where = gap < 0 ? 'none' : `${gap % VIEW.width},${Math.floor(gap / VIEW.width)}`;
      expect(where, `first uncovered pixel at distance ${DISTANCES[i]}`).toBe('none');
    }
  });

  it('draws each traffic kind and the player as a sprite, not as a fallback rectangle', () => {
    for (const kind of KINDS) {
      const target = new RecordingTarget();
      const car = trafficCar(kind, 100.4, 200.7);
      drawTraffic(target, [car], 0.5);
      expect(target.frames.map((f) => f.name), kind).toEqual([trafficSprite(kind).frame]);
      expect(target.rects, `${kind} fallback rectangles`).toEqual([]);
    }
    for (const [state, car] of PLAYERS) {
      const target = new RecordingTarget();
      drawPlayer(target, car, 0);
      expect(target.frames.map((f) => f.name), state).toEqual([playerSprite(car).frame]);
      expect(target.rects, `player ${state} fallback rectangles`).toEqual([]);
    }
  });

  it("centres each sprite's body (its frame without the shadow) on the hitbox, to the nearest pixel", () => {
    const misplaced: string[] = [];
    const check = (label: string, spec: SpriteSpec, frame: DrawnFrame | undefined, box: { x: number; y: number; w: number; h: number }) => {
      const size = sizeOf(spec.frame);
      if (!frame || !size) {
        misplaced.push(`${label}: not drawn`);
        return;
      }
      const bodyW = (size.w - spec.shadow) * frame.scale;
      const bodyH = (size.h - spec.shadow) * frame.scale;
      const dx = frame.x + bodyW / 2 - (box.x + box.w / 2);
      const dy = frame.y + bodyH / 2 - (box.y + box.h / 2);
      // Whole-pixel placement moves the centre by at most half a pixel.
      if (Math.abs(dx) > 0.5 || Math.abs(dy) > 0.5) misplaced.push(`${label}: body centre off by ${dx.toFixed(2)}, ${dy.toFixed(2)}`);
    };
    for (const kind of KINDS) {
      const target = new RecordingTarget();
      const car = trafficCar(kind, 100.4, 200.7);
      drawTraffic(target, [car], 0.5);
      check(kind, trafficSprite(kind), target.frames[0], car);
    }
    for (const [state, car] of PLAYERS) {
      const target = new RecordingTarget();
      drawPlayer(target, car, 0);
      check(`player ${state}`, playerSprite(car), target.frames[0], car);
    }
    expect(misplaced).toEqual([]);
  });

  it('tints the fuel car with the rainbow cycle and leaves other cars untinted', () => {
    const tints = (time: number) => {
      const target = new RecordingTarget();
      drawTraffic(target, KINDS.map((kind) => trafficCar(kind, 100, 100)), time);
      return Object.fromEntries(target.frames.map((f) => [f.name, f.style?.tint]));
    };
    const early = tints(0.1);
    const later = tints(0.6);
    const fuel = trafficSprite('fuelCar').frame;
    expect(early[fuel]).toBeDefined();
    expect(early[fuel]).not.toBe(later[fuel]);
    for (const kind of KINDS.filter((k) => k !== 'fuelCar')) expect(early[trafficSprite(kind).frame], kind).toBeUndefined();
  });
});
