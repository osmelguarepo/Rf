import type { GameObjects } from 'phaser';
import { LANE_WIDTH, ROAD, VIEW } from '../config';
import type { CarState } from '../game/car';
import type { TrafficCar, TrafficKind } from '../game/traffic';

/** Rectangles only: no sprites. Colours are 0xRRGGBB. */
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

const DASH_PERIOD = 40;
const TREE_PERIOD = 120;

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

/** Roadside, road, barriers, lane dashes and roadside trees. The scroll follows distance travelled. */
export function drawBackdrop(g: GameObjects.Graphics, distance: number): void {
  g.fillStyle(COLOURS.roadside, 1).fillRect(0, 0, VIEW.width, VIEW.height);
  g.fillStyle(COLOURS.road, 1).fillRect(ROAD.left, 0, ROAD.right - ROAD.left, VIEW.height);
  g.fillStyle(COLOURS.barrier, 1);
  g.fillRect(ROAD.left - 4, 0, 4, VIEW.height);
  g.fillRect(ROAD.right, 0, 4, VIEW.height);

  const dashOffset = distance % DASH_PERIOD;
  g.fillStyle(COLOURS.laneDash, 0.8);
  for (let lane = 1; lane < ROAD.laneCount; lane++) {
    const x = ROAD.left + lane * LANE_WIDTH - 2;
    for (let y = -DASH_PERIOD + dashOffset; y < VIEW.height; y += DASH_PERIOD) {
      g.fillRect(x, y, 4, 24);
    }
  }

  const treeOffset = distance % TREE_PERIOD;
  g.fillStyle(COLOURS.roadsideTree, 1);
  for (let y = -TREE_PERIOD + treeOffset; y < VIEW.height; y += TREE_PERIOD) {
    g.fillRect(14, y, 30, 18);
    g.fillRect(VIEW.width - 44, y + 60, 30, 18);
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
      return hueToColour(time * 240);
    case 'oil':
      return COLOURS.oilOuter;
  }
}

export function drawTraffic(g: GameObjects.Graphics, cars: readonly TrafficCar[], time: number): void {
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
export function drawPlayer(g: GameObjects.Graphics, car: CarState, time: number): void {
  if (car.invulnerable > 0 && Math.floor(time * 10) % 2 === 0) return;
  g.fillStyle(COLOURS.playerBody, 1).fillRect(car.x, car.y, car.w, car.h);
  g.fillStyle(COLOURS.playerWindow, 1).fillRect(car.x + 4, car.y + 6, car.w - 8, 10);
  g.fillStyle(COLOURS.playerLight, 1);
  g.fillRect(car.x, car.y + car.h - 6, 4, 4);
  g.fillRect(car.x + car.w - 4, car.y + car.h - 6, 4, 4);
}

/** Vertical gauge with a fill from the bottom. `fraction` is clamped to 0..1. */
export function drawGauge(
  g: GameObjects.Graphics,
  x: number,
  y: number,
  w: number,
  h: number,
  fraction: number,
  fillColour: number,
): void {
  g.fillStyle(0x000000, 0.6).fillRect(x, y, w, h);
  g.lineStyle(2, 0xffffff, 1).strokeRect(x, y, w, h);
  const clamped = Math.min(Math.max(fraction, 0), 1);
  g.fillStyle(fillColour, 1).fillRect(x + 2, y + h - 2 - (h - 4) * clamped, w - 4, (h - 4) * clamped);
}

/** Dim the screen and draw a centred panel (used for pause, game over and stage clear). */
export function drawPanel(g: GameObjects.Graphics, width: number, height: number): void {
  const x = (VIEW.width - width) / 2;
  const y = (VIEW.height - height) / 2;
  g.fillStyle(0x000000, 0.55).fillRect(0, 0, VIEW.width, VIEW.height);
  g.fillStyle(0x101010, 0.92).fillRect(x, y, width, height);
  g.lineStyle(3, 0xffd23f, 1).strokeRect(x, y, width, height);
}
