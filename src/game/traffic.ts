import { KMH_TO_PX, LANE_WIDTH, PLAYER, ROAD, STAGE, STEER, TRAFFIC, VIEW } from '../config';
import type { Rng } from './rng';

export type TrafficKind = 'yellow' | 'red' | 'blue' | 'truck' | 'fuelCar' | 'oil';
type CarKind = 'yellow' | 'red' | 'blue' | 'truck';

export interface TrafficCar {
  id: number;
  kind: TrafficKind;
  /** Left edge in logical pixels. */
  x: number;
  /** Top edge in logical pixels. */
  y: number;
  w: number;
  h: number;
  /** The car's own forward speed in km/h. Oil patches are 0 (static on the road). */
  kmh: number;
  /** Lane change in progress: target left edge, or null. */
  targetX: number | null;
  /** Lane changes still to make. */
  lanesLeft: number;
  /** Seconds until the next lane change may start. */
  laneTimer: number;
  /** Points for passing this car have been awarded. */
  passed: boolean;
  /** Oil: skid already triggered. Fuel car: already collected. */
  consumed: boolean;
  /** Traffic car: already bumped or struck the player, so it cannot do so again. It stays on the road. */
  struck: boolean;
}

/**
 * Spawning is driven by road distance, not time, so the density of traffic does not depend on speed.
 * Each gap counts down in px of road scrolled and spawns when it reaches 0.
 */
export interface Spawner {
  carGap: number;
  oilGap: number;
  fuelGap: number;
  nextId: number;
}

export function laneX(lane: number, w: number): number {
  return ROAD.left + lane * LANE_WIDTH + (LANE_WIDTH - w) / 2;
}

/** Lane index whose centre is closest to the car's centre. */
export function laneOf(x: number, w: number): number {
  const centre = x + w / 2;
  const lane = Math.floor((centre - ROAD.left) / LANE_WIDTH);
  return Math.min(Math.max(lane, 0), ROAD.laneCount - 1);
}

function sizeOf(kind: TrafficKind): { w: number; h: number } {
  const size = kind === 'truck' ? TRAFFIC.truck : kind === 'oil' ? TRAFFIC.oil : TRAFFIC.car;
  return { w: size.width, h: size.height };
}

/** Road distance until the next spawn of a kind. Car gaps shrink with stage but never below minSpawnGap. */
export function nextGap(kind: 'car' | 'oil' | 'fuel', stage: number, rng: Rng): number {
  const base = TRAFFIC.spawnGap[kind];
  const jitter = TRAFFIC.spawnJitter[kind];
  const gap = (base + rng.range(-jitter, jitter)) * STAGE.spawnGapScale ** (stage - 1);
  return kind === 'car' ? Math.max(gap, STAGE.minSpawnGap) : gap;
}

function ownSpeed(kind: TrafficKind, rng: Rng): number {
  switch (kind) {
    case 'yellow':
      return rng.range(TRAFFIC.yellowSpeed[0], TRAFFIC.yellowSpeed[1]);
    case 'red':
      return rng.range(TRAFFIC.redSpeed[0], TRAFFIC.redSpeed[1]);
    case 'blue':
      return rng.range(TRAFFIC.blueSpeed[0], TRAFFIC.blueSpeed[1]);
    case 'truck':
      return TRAFFIC.truckSpeed;
    case 'fuelCar':
      return TRAFFIC.fuelCarSpeed;
    case 'oil':
      return 0;
  }
}

function lanesToChange(kind: TrafficKind, rng: Rng): number {
  if (kind === 'red') return TRAFFIC.laneChangeCount.red;
  if (kind === 'blue') return rng.int(TRAFFIC.laneChangeCount.blue[0], TRAFFIC.laneChangeCount.blue[1]);
  return 0;
}

/** Picks a car type by the configured weights. */
function pickCarKind(rng: Rng): CarKind {
  const weights = TRAFFIC.carTypeWeights;
  const entries = Object.entries(weights) as [CarKind, number][];
  const total = entries.reduce((sum, [, w]) => sum + w, 0);
  let roll = rng.next() * total;
  for (const [kind, weight] of entries) {
    roll -= weight;
    if (roll < 0) return kind;
  }
  return entries[entries.length - 1][0];
}

export function createSpawner(stage: number, rng: Rng): Spawner {
  return {
    carGap: nextGap('car', stage, rng) / 2,
    oilGap: nextGap('oil', stage, rng),
    fuelGap: nextGap('fuel', stage, rng),
    nextId: 1,
  };
}

/** Creates one car just above the screen in a free lane. Returns null if every lane is busy near the top. */
function trySpawn(kind: TrafficKind, cars: readonly TrafficCar[], id: number, rng: Rng): TrafficCar | null {
  const { w, h } = sizeOf(kind);
  // A lane is busy if a car is still in the spawn zone at the top of the screen.
  const freeLanes = Array.from({ length: ROAD.laneCount }, (_, i) => i).filter(
    (lane) => !cars.some((c) => c.y < 100 && laneOf(c.x, c.w) === lane),
  );
  if (freeLanes.length === 0) return null;

  const lane = rng.pick(freeLanes);
  return {
    id,
    kind,
    x: laneX(lane, w),
    y: -h - 4,
    w,
    h,
    kmh: ownSpeed(kind, rng),
    targetX: null,
    lanesLeft: lanesToChange(kind, rng),
    laneTimer: rng.range(1, 2.5),
    passed: false,
    consumed: false,
    struck: false,
  };
}

/**
 * Counts spawn gaps down by the road scrolled this step, and adds any cars that are due.
 * A gap that cannot spawn (all lanes busy) stays at 0 and is retried on the next step.
 */
export function advanceSpawner(
  spawner: Spawner,
  cars: readonly TrafficCar[],
  stage: number,
  rng: Rng,
  scrollPx: number,
): { spawner: Spawner; cars: TrafficCar[] } {
  let { carGap, oilGap, fuelGap, nextId } = spawner;
  let out = [...cars];

  carGap -= scrollPx;
  if (carGap <= 0) {
    const car = trySpawn(pickCarKind(rng), out, nextId, rng);
    if (car) {
      out = [...out, car];
      nextId += 1;
      carGap += nextGap('car', stage, rng);
    } else {
      carGap = 0;
    }
  }

  oilGap -= scrollPx;
  if (oilGap <= 0) {
    const oil = trySpawn('oil', out, nextId, rng);
    if (oil) {
      out = [...out, oil];
      nextId += 1;
      oilGap += nextGap('oil', stage, rng);
    } else {
      oilGap = 0;
    }
  }

  fuelGap -= scrollPx;
  if (fuelGap <= 0) {
    const fuel = trySpawn('fuelCar', out, nextId, rng);
    if (fuel) {
      out = [...out, fuel];
      nextId += 1;
      fuelGap += nextGap('fuel', stage, rng);
    } else {
      fuelGap = 0;
    }
  }

  return { spawner: { carGap, oilGap, fuelGap, nextId }, cars: out };
}

export interface TrafficStepResult {
  cars: TrafficCar[];
  /** Traffic cars that just finished passing the player (points are awarded per car). */
  passedCount: number;
}

/**
 * Moves all traffic for one step.
 * Relative motion: a car slower than the player drifts down the screen, so it is passed.
 * Lane changes: red changes lane once at random. Blue changes lane 2–3 times and heads for the player's lane when close.
 */
export function stepTraffic(
  cars: readonly TrafficCar[],
  playerKmh: number,
  playerX: number,
  rng: Rng,
  dt: number,
): TrafficStepResult {
  let passedCount = 0;
  const playerTop = PLAYER.y;
  const playerBottom = PLAYER.y + PLAYER.height;

  const next: TrafficCar[] = [];
  for (const car of cars) {
    const c = { ...car };
    c.y += (playerKmh - c.kmh) * KMH_TO_PX * dt;

    // Lane change timing and target.
    if (c.targetX === null && c.lanesLeft > 0 && c.kind !== 'oil' && c.kind !== 'fuelCar') {
      c.laneTimer -= dt;
      if (c.laneTimer <= 0) {
        const currentLane = laneOf(c.x, c.w);
        const targetLane = pickLaneTarget(c, currentLane, playerX, playerTop, playerBottom, rng);
        if (targetLane !== currentLane) {
          c.targetX = laneX(targetLane, c.w);
          c.lanesLeft -= 1;
        }
        c.laneTimer = rng.range(1.5, 3);
      }
    }
    if (c.targetX !== null) {
      const step = STEER.laneChangeSpeed * dt;
      const delta = c.targetX - c.x;
      if (Math.abs(delta) <= step) {
        c.x = c.targetX;
        c.targetX = null;
      } else {
        c.x += Math.sign(delta) * step;
      }
    }

    if (!c.passed && c.kind !== 'oil' && c.kind !== 'fuelCar' && c.y > playerBottom) {
      c.passed = true;
      passedCount += 1;
    }

    const offBottom = c.y > VIEW.height + 20;
    const offTop = c.y + c.h < -120;
    if (!offBottom && !offTop) next.push(c);
  }

  return { cars: next, passedCount };
}

function pickLaneTarget(
  car: TrafficCar,
  currentLane: number,
  playerX: number,
  playerTop: number,
  playerBottom: number,
  rng: Rng,
): number {
  const others = Array.from({ length: ROAD.laneCount }, (_, i) => i).filter((l) => l !== currentLane);
  if (car.kind === 'blue') {
    const playerLane = laneOf(playerX, PLAYER.width);
    const near = car.y + car.h > playerTop - 200 && car.y < playerBottom;
    if (near && playerLane !== currentLane) return playerLane;
  }
  return rng.pick(others);
}
