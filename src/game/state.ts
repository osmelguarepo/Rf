import { KMH_TO_PX, PLAYER, SCORE, SIM_STEP } from '../config';
import {
  applyCrash,
  createCar,
  isSkidding,
  startSkid,
  stepGear,
  stepLateral,
  stepSpeed,
  tickInvulnerable,
  type CarState,
} from './car';
import { applyCrashFuel, collectFuelCar, createFuel, drainFuel, isEmpty, type FuelState } from './fuel';
import { overlaps } from './collision';
import { createRng, type Rng } from './rng';
import { stageClearBonus, stageGoal } from './stage';
import {
  createSpawner,
  laneX,
  stepSpawner,
  stepTraffic,
  type Spawner,
  type TrafficCar,
} from './traffic';
import type { GameInput } from './types';

export type Phase = 'running' | 'paused' | 'stageClear' | 'gameOver';

/** Things that happened during the last step, for HUD messages, flashes and sound-free feedback. */
export type GameEvent =
  | 'skid'
  | 'crash'
  | 'spin'
  | 'pickup'
  | 'pass'
  | 'stageClear'
  | 'gameOver'
  | 'pause'
  | 'resume';

export interface GameState {
  phase: Phase;
  stage: number;
  /** Road distance covered this stage, in px. */
  distance: number;
  goal: number;
  car: CarState;
  fuel: FuelState;
  traffic: TrafficCar[];
  spawner: Spawner;
  score: number;
  /** Best score this session. Kept by the caller across restarts. */
  highScore: number;
  /** Seconds of running time this stage. */
  time: number;
  /** Mutable RNG. Determinism comes from the seed, not from purity. */
  rng: Rng;
  events: GameEvent[];
}

export function createGame(seed: number, highScore = 0): GameState {
  const rng = createRng(seed);
  const stage = 1;
  return {
    phase: 'running',
    stage,
    distance: 0,
    goal: stageGoal(stage),
    car: createCar(laneX(1, PLAYER.width)),
    fuel: createFuel(),
    traffic: [],
    spawner: createSpawner(stage, rng),
    score: 0,
    highScore,
    time: 0,
    rng,
    events: [],
  };
}

/** Starts the next stage: keeps score, fuel and car, clears the road, reseeds traffic for the new difficulty. */
function nextStage(state: GameState): GameState {
  const stage = state.stage + 1;
  return {
    ...state,
    phase: 'running',
    stage,
    distance: 0,
    goal: stageGoal(stage),
    traffic: [],
    spawner: createSpawner(stage, state.rng),
    time: 0,
    events: [],
  };
}

/** Advances the game by one fixed step. The caller passes SIM_STEP as dt (see src/config.ts). */
export function step(state: GameState, input: GameInput, dt: number = SIM_STEP): GameState {
  const events: GameEvent[] = [];

  if (state.phase === 'gameOver') {
    return { ...state, events: [] };
  }

  if (state.phase === 'stageClear') {
    if (input.confirmPressed) return nextStage(state);
    return { ...state, events: [] };
  }

  if (state.phase === 'paused') {
    if (input.pausePressed) return { ...state, phase: 'running', events: ['resume'] };
    return { ...state, events: [] };
  }

  if (input.pausePressed) {
    return { ...state, phase: 'paused', events: ['pause'] };
  }

  return runStep(state, input, dt, events);
}

function runStep(state: GameState, input: GameInput, dt: number, events: GameEvent[]): GameState {
  const rng = state.rng;

  // 1. Car: gear, speed, lateral motion (steering, skid, road edges).
  const gear = stepGear(state.car.gear, input);
  const speed = stepSpeed(state.car.speed, gear, input, dt);
  let car: CarState = { ...state.car, gear, speed };

  const lateral = stepLateral(car, input, dt);
  car = { ...car, x: lateral.x, slideVx: lateral.slideVx };

  let fuel = state.fuel;
  let gameOver = false;

  // Spin-out: the car reached the roadside while sliding. Counts as a crash.
  if (lateral.spunOut && car.invulnerable <= 0) {
    car = applyCrash(car);
    fuel = applyCrashFuel(fuel, rng);
    events.push('spin', 'crash');
  }

  car = tickInvulnerable(car, dt);

  // 2. Road distance and traffic motion.
  const distance = state.distance + car.speed * KMH_TO_PX * dt;
  const moved = stepTraffic(state.traffic, car.speed, car.x, rng, dt);
  let score = state.score;
  if (moved.passedCount > 0) {
    score += moved.passedCount * SCORE.perPassedCar;
    events.push('pass');
  }

  // 3. Spawn new traffic.
  const spawned = stepSpawner(state.spawner, moved.cars, state.stage, rng, dt);
  const traffic = spawned.cars;

  // 4. Collisions with the player car.
  const playerRect = { x: car.x, y: car.y, w: car.w, h: car.h };
  for (const t of traffic) {
    if (t.consumed || !overlaps(playerRect, t)) continue;

    if (t.kind === 'oil') {
      t.consumed = true;
      if (!isSkidding(car)) {
        car = startSkid(car, rng.next() < 0.5 ? -1 : 1);
        events.push('skid');
      }
      continue;
    }

    if (t.kind === 'fuelCar') {
      t.consumed = true;
      const picked = collectFuelCar(fuel);
      fuel = picked.fuel;
      score += picked.points;
      events.push('pickup');
      continue;
    }

    if (car.invulnerable > 0) continue;

    if (t.kind === 'truck') {
      // Trucks destroy the car on contact: game over.
      gameOver = true;
      break;
    }

    // Yellow, red and blue cars: a crash. Each car can only crash the player once.
    if (t.struck) continue;
    t.struck = true;
    car = applyCrash(car);
    fuel = applyCrashFuel(fuel, rng);
    events.push('crash');
  }

  // 5. Fuel drain and empty tank.
  fuel = drainFuel(fuel, car.speed, dt);
  if (isEmpty(fuel)) gameOver = true;

  const survivors = traffic.filter((t) => !t.consumed);

  const base: GameState = {
    ...state,
    car,
    fuel,
    distance,
    score,
    traffic: survivors,
    spawner: spawned.spawner,
    time: state.time + dt,
    events,
  };

  if (gameOver) {
    events.push('gameOver');
    return { ...base, phase: 'gameOver', highScore: Math.max(state.highScore, score) };
  }

  if (distance >= state.goal) {
    const bonus = stageClearBonus(fuel.amount);
    events.push('stageClear');
    const scored = score + bonus;
    return {
      ...base,
      phase: 'stageClear',
      score: scored,
      highScore: Math.max(state.highScore, scored),
    };
  }

  return { ...base, highScore: Math.max(state.highScore, score) };
}
