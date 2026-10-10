import type { GameObjects } from 'phaser';
import { INVULNERABLE_BLINK_HZ, LANE_WIDTH, ROAD, SPRITE, VIEW } from '../config';
import type { CarState } from '../game/car';
import type { Rect } from '../game/collision';
import type { TrafficCar, TrafficKind } from '../game/traffic';

/**
 * Drawing for the road, traffic, player and HUD.
 *
 * drawBackdrop, drawTraffic and drawPlayer draw on either target:
 * - a SpriteTarget (SpriteLayer in src/render/sprites.ts): frames from the sprite atlas at whole-number scales;
 * - a Graphics object: flat rectangles, the MVP's original look. Scenes fall back to it if the atlas did not load.
 *
 * Hitboxes never change. Each sprite is placed so that its body is centred on the object's logical rectangle.
 */

/** Colours of the rectangle look, as 0xRRGGBB. */
export const COLOURS = {
  roadside: 0x1e6b2e,
  roadsideTree: 0x145a22,
  road: 0x3a3a3a,
  barrier: 0xdddddd,
  laneDash: 0xf0f0f0,
  playerBody: 0xe74c3c,
  playerWindow: 0xbde0ff,
  playerLight: 0xffe066,
  yellow: 0xf4d03f,
  red: 0xc0392b,
  blue: 0x2e86de,
  truck: 0x7f8c8d,
  oilOuter: 0x222222,
  oilInner: 0x000000,
} as const;

/** Colours picked from the sprite sheet, for parts drawn in code next to sprites: lane dashes, gauges, panels. */
export const PALETTE = {
  black: 0x141414,
  white: 0xf0eeec,
  grey: 0xa69f96,
  asphalt: 0x67615f,
  grass: 0x42ad37,
  yellow: 0xf1bb3b,
  red: 0xae2633,
  lightRed: 0xf26864,
} as const;

/** Optional settings for one sprite frame. */
export interface FrameStyle {
  /** Multiplies the frame's colours (0xRRGGBB). The fuel car's rainbow is a tint. */
  tint?: number;
  alpha?: number;
  flipX?: boolean;
}

/** Draws sprite frames and flat rectangles, in call order. SpriteLayer implements it. */
export interface SpriteTarget {
  /** Size of a frame in texture pixels, or undefined if there is no such frame. */
  frameSize(name: string): { w: number; h: number } | undefined;
  /** Draws a frame scaled by a whole number, with its top-left corner at (x, y). */
  drawFrame(name: string, x: number, y: number, scale: number, style?: FrameStyle): void;
  /** Draws a flat rectangle. */
  drawRect(x: number, y: number, w: number, h: number, colour: number, alpha?: number): void;
}

/** What the world drawing functions accept. A Graphics object gets the rectangle look. */
export type DrawTarget = GameObjects.Graphics | SpriteTarget;

function isSpriteTarget(target: DrawTarget): target is SpriteTarget {
  return typeof (target as Partial<SpriteTarget>).drawFrame === 'function';
}

/** A frame, the whole-number scale it is drawn at, and the width of its shadow in texture pixels. */
export interface SpriteSpec {
  readonly frame: string;
  readonly scale: number;
  readonly shadow: number;
}

/** The white barriers just outside the road: x ROAD.left − 4 to ROAD.left, and ROAD.right to ROAD.right + 4. */
const BARRIER_WIDTH = 4;
const DASH_PERIOD = 40;
const DASH_LENGTH = 24;
const DASH_WIDTH = 4;
const TREE_PERIOD = 120;
/** Right-hand trees and bushes trail the left-hand ones by this much, so the two sides do not line up. */
const TREE_STAGGER = 60;

/** Converts a hue in degrees to 0xRRGGBB at full saturation and value. Used for the rainbow fuel cars. */
export function hueToColour(hue: number): number {
  const h = ((hue % 360) + 360) % 360;
  const section = Math.floor(h / 60);
  const f = h / 60 - section;
  const q = 1 - f;
  const [r, g, b] = [
    [1, f, 0],
    [q, 1, 0],
    [0, 1, f],
    [0, q, 1],
    [f, 0, 1],
    [1, 0, q],
  ][section] as [number, number, number];
  const toByte = (v: number): number => Math.round(v * 255);
  return (toByte(r) << 16) | (toByte(g) << 8) | toByte(b);
}

/** 0xRRGGBB → '#rrggbb', for the canvas and text styles. */
export function cssColour(colour: number): string {
  return `#${colour.toString(16).padStart(6, '0')}`;
}

/** The fuel car's colour at a given time: a full trip round the hue circle every 1.5 s. */
export function fuelCarColour(time: number): number {
  return hueToColour(time * 240);
}

/** Blink rule: while invulnerable, the player car is hidden on every other tenth of a second. */
export function playerVisible(car: CarState, time: number): boolean {
  return !(car.invulnerable > 0 && Math.floor(time * INVULNERABLE_BLINK_HZ) % 2 === 0);
}

/** The player's sprite: upright, or turned 45° towards the slide while skidding. */
export function playerSprite(car: CarState): SpriteSpec {
  if (car.slideVx > 0) return SPRITE.playerSkidRight;
  if (car.slideVx < 0) return SPRITE.playerSkidLeft;
  return SPRITE.player;
}

export function trafficSprite(kind: TrafficKind): SpriteSpec {
  return SPRITE.traffic[kind];
}

/** Top-left corner that centres a sprite's body (its frame without the shadow) on a hitbox, in whole pixels. */
export function placeOnHitbox(sprite: SpriteSpec, size: { w: number; h: number }, box: Rect): { x: number; y: number } {
  const bodyW = (size.w - sprite.shadow) * sprite.scale;
  const bodyH = (size.h - sprite.shadow) * sprite.scale;
  return { x: Math.round(box.x + (box.w - bodyW) / 2), y: Math.round(box.y + (box.h - bodyH) / 2) };
}

/** Draws a sprite centred on a hitbox. If the frame is missing, the hitbox is drawn as a flat rectangle instead. */
function drawOnHitbox(target: SpriteTarget, sprite: SpriteSpec, box: Rect, fallback: number, style?: FrameStyle): void {
  const size = target.frameSize(sprite.frame);
  if (!size) {
    target.drawRect(box.x, box.y, box.w, box.h, fallback);
    return;
  }
  const at = placeOnHitbox(sprite, size, box);
  target.drawFrame(sprite.frame, at.x, at.y, sprite.scale, style);
}

// Road tiles. The sheet's edge tiles carry a white line one tile pixel wide: the 2nd column of the left tile and the
// 7th of the right one. At SPRITE.tileScale a tile pixel is as wide as a barrier, so placing the tiles as below puts
// the lines exactly on the barriers (x 56–60 and 300–304), and the road between them still spans ROAD.left to ROAD.right.
const TILE = SPRITE.tileSize * SPRITE.tileScale;
const EDGE_LINE_COLUMN = { left: 1, right: 6 } as const;
const EDGE_LEFT_X = ROAD.left - BARRIER_WIDTH - EDGE_LINE_COLUMN.left * SPRITE.tileScale;
const EDGE_RIGHT_X = ROAD.right - EDGE_LINE_COLUMN.right * SPRITE.tileScale;
const VERGE_LEFT_X = EDGE_LEFT_X - TILE;
const VERGE_RIGHT_X = EDGE_RIGHT_X + TILE;
/** The verge tiles are grass for 5 of their 8 columns, so there are 40 px of grass on each side of the road. */
const GRASS_WIDTH = VERGE_LEFT_X + 5 * SPRITE.tileScale;

interface TileColumn {
  readonly x: number;
  /** null for grass, whose frame varies by row. */
  readonly frame: string | null;
}

/** One row of the road, left to right. Asphalt comes before the edge tiles, so an edge tile covers any overlap. */
function roadColumns(): TileColumn[] {
  const columns: TileColumn[] = [];
  for (let x = VERGE_LEFT_X - TILE; x > -TILE; x -= TILE) columns.push({ x, frame: null });
  columns.push({ x: VERGE_LEFT_X, frame: SPRITE.road.vergeLeft });
  for (let x = EDGE_LEFT_X + TILE; x < EDGE_RIGHT_X; x += TILE) columns.push({ x, frame: SPRITE.road.asphalt });
  columns.push({ x: EDGE_LEFT_X, frame: SPRITE.road.edgeLeft });
  columns.push({ x: EDGE_RIGHT_X, frame: SPRITE.road.edgeRight });
  columns.push({ x: VERGE_RIGHT_X, frame: SPRITE.road.vergeRight });
  for (let x = VERGE_RIGHT_X + TILE; x < VIEW.width; x += TILE) columns.push({ x, frame: null });
  return columns;
}

const ROAD_COLUMNS = roadColumns();

/** Grass varies by row, and the two sides are offset so they do not mirror each other. */
function grassFrame(row: number, x: number): string {
  const variants = SPRITE.road.grass;
  const shift = x < ROAD.left ? 0 : 3;
  return variants[(((row + shift) % variants.length) + variants.length) % variants.length];
}

function drawRoadSprites(target: SpriteTarget, distance: number): void {
  const travelled = Math.floor(distance);

  // Flat colours first: if a tile frame were missing, the road would keep its colours instead of showing a hole.
  target.drawRect(0, 0, VIEW.width, VIEW.height, PALETTE.grass);
  target.drawRect(ROAD.left - BARRIER_WIDTH, 0, ROAD.right - ROAD.left + BARRIER_WIDTH * 2, VIEW.height, PALETTE.asphalt);

  // Tile rows scroll down as the car drives on. `row` numbers rows along the road, so grass variants move with it.
  let row = Math.floor(travelled / TILE) + 1;
  for (let y = (travelled % TILE) - TILE; y < VIEW.height; y += TILE, row -= 1) {
    for (const column of ROAD_COLUMNS) {
      target.drawFrame(column.frame ?? grassFrame(row, column.x), column.x, y, SPRITE.tileScale);
    }
  }

  // Lane dashes: the sheet has none for a three-lane road, so they are drawn in code, as before.
  const dashOffset = travelled % DASH_PERIOD;
  for (let lane = 1; lane < ROAD.laneCount; lane++) {
    const x = ROAD.left + lane * LANE_WIDTH - DASH_WIDTH / 2;
    for (let y = dashOffset - DASH_PERIOD; y < VIEW.height; y += DASH_PERIOD) {
      target.drawRect(x, y, DASH_WIDTH, DASH_LENGTH, PALETTE.white);
    }
  }

  // Bushes, centred on the grass strips, where the rectangle look had trees.
  const bush = target.frameSize(SPRITE.bush.frame);
  if (!bush) return;
  const size = bush.w * SPRITE.bush.scale;
  const leftX = (GRASS_WIDTH - size) / 2;
  const rightX = VIEW.width - GRASS_WIDTH + (GRASS_WIDTH - size) / 2;
  for (let y = (travelled % TREE_PERIOD) - TREE_PERIOD; y < VIEW.height; y += TREE_PERIOD) {
    target.drawFrame(SPRITE.bush.frame, leftX, y, SPRITE.bush.scale);
    target.drawFrame(SPRITE.bush.frame, rightX, y + TREE_STAGGER, SPRITE.bush.scale);
  }
}

/** Roadside, road, barriers, lane dashes and roadside scenery. The scroll follows distance travelled. */
export function drawBackdrop(target: DrawTarget, distance: number): void {
  if (isSpriteTarget(target)) {
    drawRoadSprites(target, distance);
    return;
  }

  const g = target;
  g.fillStyle(COLOURS.roadside, 1).fillRect(0, 0, VIEW.width, VIEW.height);
  g.fillStyle(COLOURS.road, 1).fillRect(ROAD.left, 0, ROAD.right - ROAD.left, VIEW.height);
  g.fillStyle(COLOURS.barrier, 1);
  g.fillRect(ROAD.left - BARRIER_WIDTH, 0, BARRIER_WIDTH, VIEW.height);
  g.fillRect(ROAD.right, 0, BARRIER_WIDTH, VIEW.height);

  const dashOffset = distance % DASH_PERIOD;
  g.fillStyle(COLOURS.laneDash, 0.8);
  for (let lane = 1; lane < ROAD.laneCount; lane++) {
    const x = ROAD.left + lane * LANE_WIDTH - DASH_WIDTH / 2;
    for (let y = -DASH_PERIOD + dashOffset; y < VIEW.height; y += DASH_PERIOD) {
      g.fillRect(x, y, DASH_WIDTH, DASH_LENGTH);
    }
  }

  const treeOffset = distance % TREE_PERIOD;
  g.fillStyle(COLOURS.roadsideTree, 1);
  for (let y = -TREE_PERIOD + treeOffset; y < VIEW.height; y += TREE_PERIOD) {
    g.fillRect(14, y, 30, 18);
    g.fillRect(VIEW.width - 44, y + TREE_STAGGER, 30, 18);
  }
}

function trafficColour(kind: TrafficKind, time: number): number {
  switch (kind) {
    case 'yellow':
      return COLOURS.yellow;
    case 'red':
      return COLOURS.red;
    case 'blue':
      return COLOURS.blue;
    case 'truck':
      return COLOURS.truck;
    case 'fuelCar':
      return fuelCarColour(time);
    case 'oil':
      return COLOURS.oilOuter;
  }
}

export function drawTraffic(target: DrawTarget, cars: readonly TrafficCar[], time: number): void {
  if (isSpriteTarget(target)) {
    // Oil lies on the road, so it goes under every car.
    for (const car of cars) {
      if (car.kind === 'oil') drawOnHitbox(target, trafficSprite('oil'), car, COLOURS.oilOuter);
    }
    for (const car of cars) {
      if (car.kind === 'oil') continue;
      const colour = trafficColour(car.kind, time);
      drawOnHitbox(target, trafficSprite(car.kind), car, colour, car.kind === 'fuelCar' ? { tint: colour } : undefined);
    }
    return;
  }

  const g = target;
  for (const car of cars) {
    g.fillStyle(trafficColour(car.kind, time), 1).fillRect(car.x, car.y, car.w, car.h);
    if (car.kind === 'oil') {
      g.fillStyle(COLOURS.oilInner, 1).fillRect(car.x + 6, car.y + 6, car.w - 12, car.h - 12);
    } else if (car.kind !== 'truck') {
      // Windscreen on traffic cars, so their direction reads at a glance.
      g.fillStyle(COLOURS.playerWindow, 0.6).fillRect(car.x + 4, car.y + 6, car.w - 8, 8);
    }
  }
}

/** The player car. Blinks while invulnerable after a crash. */
export function drawPlayer(target: DrawTarget, car: CarState, time: number): void {
  if (!playerVisible(car, time)) return;
  if (isSpriteTarget(target)) {
    drawOnHitbox(target, playerSprite(car), car, COLOURS.playerBody);
    return;
  }

  const g = target;
  g.fillStyle(COLOURS.playerBody, 1).fillRect(car.x, car.y, car.w, car.h);
  g.fillStyle(COLOURS.playerWindow, 1).fillRect(car.x + 4, car.y + 6, car.w - 8, 10);
  g.fillStyle(COLOURS.playerLight, 1);
  g.fillRect(car.x, car.y + car.h - 6, 4, 4);
  g.fillRect(car.x + car.w - 4, car.y + car.h - 6, 4, 4);
}

/**
 * Vertical gauge with a fill from the bottom, drawn like the sheet's fuel gauge: a white rim, a black gap, then the bar.
 * The sheet's own gauge has its fill baked in, so the gauge is drawn in code. `fraction` is clamped to 0..1.
 */
export function drawGauge(
  g: GameObjects.Graphics,
  x: number,
  y: number,
  w: number,
  h: number,
  fraction: number,
  fillColour: number,
): void {
  const rim = 2;
  const inset = rim * 2;
  g.fillStyle(PALETTE.white, 1).fillRect(x, y, w, h);
  g.fillStyle(PALETTE.black, 1).fillRect(x + rim, y + rim, w - rim * 2, h - rim * 2);
  const clamped = Math.min(Math.max(fraction, 0), 1);
  const fill = Math.round((h - inset * 2) * clamped);
  g.fillStyle(fillColour, 1).fillRect(x + inset, y + h - inset - fill, w - inset * 2, fill);
}

/** A box with a solid border, drawn with fills so its edges stay on whole pixels. */
export function drawBox(
  g: GameObjects.Graphics,
  x: number,
  y: number,
  w: number,
  h: number,
  border: number = PALETTE.yellow,
  fillAlpha = 0.92,
): void {
  const b = 2;
  g.fillStyle(PALETTE.black, fillAlpha).fillRect(x + b, y + b, w - b * 2, h - b * 2);
  g.fillStyle(border, 1);
  g.fillRect(x, y, w, b);
  g.fillRect(x, y + h - b, w, b);
  g.fillRect(x, y + b, b, h - b * 2);
  g.fillRect(x + w - b, y + b, b, h - b * 2);
}

/** Dim the screen and draw a centred panel (used for pause, game over and stage clear). */
export function drawPanel(g: GameObjects.Graphics, width: number, height: number): void {
  const x = Math.round((VIEW.width - width) / 2);
  const y = Math.round((VIEW.height - height) / 2);
  g.fillStyle(0x000000, 0.55).fillRect(0, 0, VIEW.width, VIEW.height);
  drawBox(g, x, y, width, height);
}
