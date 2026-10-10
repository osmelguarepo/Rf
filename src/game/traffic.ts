import { KMH_TO_PX, LANE_WIDTH, PLAYER, ROAD, STAGE, STEER, TRAFFIC, VIEW } from '../config';
import type { Rng } from './rng';

export type TrafficKind = 'yellow' | 'red' | 'blue' | 'truck' | 'fuelCar' | 'oil';

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
  /** Traffic car: has already crashed into the player, so it cannot crash again. It stays on the road. */
  struck: boolean;
}

export type SpawnTimers = Record<TrafficKind, number>;

export interface Spawner {
  timers: SpawnTimers;
  nextId: number;
}

export const SPAWN_KINDS: readonly TrafficKind[] = ['yellow', 'red', 'blue', 'truck', 'fuelCar', 'oil'];

/** Left edge of a lane for a car of width w, centred in that lane. */
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

/** Stage multiplier for traffic speed (1.05^(stage-1)). */
export function stageSpeedScale(stage: number): number {
  return STAGE.trafficSpeedScale ** (stage - 1);
}

/** Stage multiplier for spawn intervals (0.9^(stage-1)). Smaller = busier road. */
export function stageIntervalScale(stage: number): number {
  return STAGE.spawnIntervalScale ** (stage - 1);
}

function ownSpeed(kind: TrafficKind, rng: Rng, stage: number): number {
  const scale = stageSpeedScale(stage);
  switch (kind) {
    case 'yellow':
      return rng.range(TRAFFIC.yellowSpeed[0], TRAFFIC.yellowSpeed[1]) * scale;
    case 'red':
      return rng.range(TRAFFIC.redSpeed[0], TRAFFIC.redSpeed[1]) * scale;
    case 'blue':
      return rng.range(TRAFFIC.blueSpeed[0], TRAFFIC.blueSpeed[1]) * scale;
    case 'truck':
      return TRAFFIC.truckSpeed * scale;
    case 'fuelCar':
      return TRAFFIC.fuelCarSpeed * scale;
    case 'oil':
      return 0;
  }
}

function lanesToChange(kind: TrafficKind, rng: Rng): number {
  if (kind === 'red') return TRAFFIC.laneChangeCount.red;
  if (kind === 'blue') return rng.int(TRAFFIC.laneChangeCount.blue[0], TRAFFIC.laneChangeCount.blue[1]);
  return 0;
}

export function createSpawner(stage: number, rng: Rng): Spawner {
  const timers = {} as SpawnTimers;
  for (const kind of SPAWN_KINDS) {
    timers[kind] = nextInterval(kind, stage, rng);
  }
  return { timers, nextId: 1 };
}

function nextInterval(kind: TrafficKind, stage: number, rng: Rng): number {
  const base = TRAFFIC.spawnInterval[kind];
  return base * stageIntervalScale(stage) * rng.range(0.7, 1.3);
}

/** Creates one car just above the screen in a free lane. Returns null if every lane is busy near the top. */
function trySpawn(
  kind: TrafficKind,
  cars: readonly TrafficCar[],
  id: number,
  stage: number,
  rng: Rng,
): TrafficCar | null {
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
    kmh: ownSpeed(kind, rng, stage),
    targetX: null,
    lanesLeft: lanesToChange(kind, rng),
    laneTimer: rng.range(1, 2.5),
    passed: false,
    consumed: false,
    struck: false,
  };
}

/** Advances spawn timers and adds any cars that are due. */
export function stepSpawner(
  spawner: Spawner,
  cars: readonly TrafficCar[],
  stage: number,
  rng: Rng,
  dt: number,
): { spawner: Spawner; cars: TrafficCar[] } {
  const timers = { ...spawner.timers };
  let nextId = spawner.nextId;
  let out = [...cars];

  for (const kind of SPAWN_KINDS) {
    timers[kind] -= dt;
    if (timers[kind] > 0) continue;

    const car = trySpawn(kind, out, nextId, stage, rng);
    if (car) {
      out = [...out, car];
      nextId += 1;
      timers[kind] = nextInterval(kind, stage, rng);
    } else {
      // No free lane right now; retry on the next step.
      timers[kind] = 0.1;
    }
  }

  return { spawner: { timers, nextId }, cars: out };
}

export interface TrafficStepResult {
  cars: TrafficCar[];
  /** Traffic cars that just finished passing the player (points are awarded per car). */
  passedCount: number;
}

/**
 * Moves all traffic for one step.
 * Relative motion: a car with a lower speed than the player drifts down the screen, so it is passed.
 * Lane changes: red changes lanes once at random. Blue changes lanes 2–3 times and heads for the player's lane when close.
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
    let c = { ...car };
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
