/**
 * Golden traces of the Phaser rules for the Godot port (docs/GODOT_PLAN.md §6).
 *
 * Runs the TypeScript rules in src/game (commit 0a0841f) and writes tests/golden/phaser_golden.json, which the
 * GDScript tests in tests/test_golden.gd replay. How to run it again: tools/gen_golden/README.md.
 *
 * Encoding rules, so nothing is lost on the way to GDScript:
 * - doubles are the 8 bytes of the IEEE-754 value, little-endian, as 16 hex digits (never decimal text);
 * - RNG outputs are the u32 behind next() (next() * 2^32, which is exact);
 * - inputs are the Godot input byte (scripts/sim/player_input.gd): bit 0 accel, bit 1 brake, bits 2-3 steer + 1,
 *   bit 4 high gear, bit 5 pause, bit 6 confirm;
 * - durations that Phaser keeps as float seconds are written as the number of 1/60 s steps Phaser still needs to
 *   count them down to zero, which is what the Godot port stores (integer ticks).
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { PLAYER, SIM_STEP } from '../../src/config';
import { gearFor, stepSpeed } from '../../src/game/car';
import { createRng } from '../../src/game/rng';
import { createGame, step, type GameEvent, type GameState, type Phase } from '../../src/game/state';
import { laneOf, laneX, type TrafficCar, type TrafficKind } from '../../src/game/traffic';
import type { GameInput } from '../../src/game/types';

const ROOT = fileURLToPath(new URL('../..', import.meta.url));
const OUT = process.env.GOLDEN_OUT ?? join(ROOT, 'tests', 'golden', 'phaser_golden.json');
const DT = SIM_STEP;

// Codes shared with the GDScript side. The JSON carries these lists, so the test can map names to its constants.
const KINDS: readonly TrafficKind[] = ['yellow', 'red', 'blue', 'truck', 'fuelCar', 'oil'];
const PHASES: readonly Phase[] = ['running', 'paused', 'stageClear', 'gameOver'];
const EVENTS: readonly GameEvent[] = ['skid', 'bump', 'crash', 'spin', 'pickup', 'pass', 'stageClear', 'gameOver', 'pause', 'resume'];

const ACCEL = 1;
const BRAKE = 2;
const STEER_LEFT = 0 << 2;
const STEER_NONE = 1 << 2;
const STEER_RIGHT = 2 << 2;
const HIGH = 16;
const PAUSE = 32;
const CONFIRM = 64;

function decode(byte: number): GameInput {
  const steer = (byte >> 2) & 3;
  return {
    accel: (byte & ACCEL) !== 0,
    brake: (byte & BRAKE) !== 0,
    steer: steer === 0 ? -1 : steer === 2 ? 1 : 0,
    highGear: (byte & HIGH) !== 0,
    pausePressed: (byte & PAUSE) !== 0,
    confirmPressed: (byte & CONFIRM) !== 0,
  };
}

function steerBits(steer: number): number {
  return steer < 0 ? STEER_LEFT : steer > 0 ? STEER_RIGHT : STEER_NONE;
}

function hex(value: number): string {
  const bytes = Buffer.alloc(8);
  bytes.writeDoubleLE(value, 0);
  return bytes.toString('hex');
}

/** The two little-endian u32 words of a double, for hashing. */
function words(value: number): [number, number] {
  const bytes = Buffer.alloc(8);
  bytes.writeDoubleLE(value, 0);
  return [bytes.readUInt32LE(0), bytes.readUInt32LE(4)];
}

/** One FNV-1a style round on a u32 word. GDScript: ((h ^ v) * 16777619) & 0xFFFFFFFF. */
function mix(h: number, v: number): number {
  return Math.imul((h ^ v) >>> 0, 16777619) >>> 0;
}

function mixDouble(h: number, value: number): number {
  const [lo, hi] = words(value);
  return mix(mix(h, lo), hi);
}

const FNV_OFFSET = 2166136261;

/** Steps Phaser still needs to count a float-seconds timer down to zero (laneTimer, invulnerable). */
function ticksLeft(seconds: number): number {
  let value = seconds;
  let n = 0;
  while (value > 0) {
    value = Math.max(0, value - DT);
    n += 1;
  }
  return n;
}

function eventMask(events: readonly GameEvent[]): number {
  let mask = 0;
  for (const event of events) mask |= 1 << EVENTS.indexOf(event);
  return mask;
}

/** Exact traffic state (everything but the screen y, which the port computes from world coordinates). */
function trafficHash(traffic: readonly TrafficCar[]): number {
  let h = mix(FNV_OFFSET, traffic.length);
  for (const c of traffic) {
    h = mix(h, c.id);
    h = mix(h, KINDS.indexOf(c.kind));
    h = mixDouble(h, c.x);
    h = mixDouble(h, c.kmh);
    h = mix(h, c.targetX === null ? 0 : 1);
    if (c.targetX !== null) h = mixDouble(h, c.targetX);
    h = mix(h, c.lanesLeft);
    h = mix(h, (c.passed ? 1 : 0) | (c.struck ? 2 : 0) | (c.consumed ? 4 : 0));
    h = mix(h, ticksLeft(c.laneTimer));
  }
  return h;
}

/** Player state that is not written out column by column. */
function playerHash(s: GameState): number {
  let h = mixDouble(FNV_OFFSET, s.car.slideVx);
  h = mix(h, ticksLeft(s.car.invulnerable));
  h = mix(h, s.car.gear === 'high' ? 1 : 0);
  h = mix(h, s.highScore);
  h = mix(h, Math.round(s.time / DT));
  h = mixDouble(h, s.goal);
  return h;
}

function snapshot(tick: number, s: GameState): unknown {
  return {
    tick,
    phase: PHASES.indexOf(s.phase),
    stage: s.stage,
    goal: hex(s.goal),
    distance: hex(s.distance),
    score: s.score,
    high_score: s.highScore,
    stage_ticks: Math.round(s.time / DT),
    car: {
      x: hex(s.car.x),
      speed: hex(s.car.speed),
      gear: s.car.gear === 'high' ? 1 : 0,
      slide_vx: hex(s.car.slideVx),
      invulnerable_ticks: ticksLeft(s.car.invulnerable),
    },
    fuel: hex(s.fuel.amount),
    spawner: {
      car_gap: hex(s.spawner.carGap),
      oil_gap: hex(s.spawner.oilGap),
      fuel_gap: hex(s.spawner.fuelGap),
      next_id: s.spawner.nextId,
    },
    // [id, kind, x, screen y, w, h, kmh, target x or "", lanes left, lane timer ticks, passed, struck, consumed]
    traffic: s.traffic.map((c) => [
      c.id,
      KINDS.indexOf(c.kind),
      hex(c.x),
      hex(c.y),
      c.w,
      c.h,
      hex(c.kmh),
      c.targetX === null ? '' : hex(c.targetX),
      c.lanesLeft,
      ticksLeft(c.laneTimer),
      c.passed ? 1 : 0,
      c.struck ? 1 : 0,
      c.consumed ? 1 : 0,
    ]),
  };
}

// ---------------------------------------------------------------------------------------------------------------
// 1. RNG

function rngSection(): unknown {
  const seeds = [0, 1, 7, 42, 2024, 123456789, 20261014, 0x7fffffff, 0x80000000, 0xffffffff];
  const first = seeds.map((seed) => {
    const rng = createRng(seed);
    return { seed, u32: Array.from({ length: 64 }, () => rng.next() * 4294967296) };
  });

  // 1 000 000 outputs of one seed, summarised: xor, sum mod 2^32, an FNV hash, and every 100 000th output.
  const millionSeed = 20261014;
  const rng = createRng(millionSeed);
  let xor = 0;
  let sum = 0;
  let h = FNV_OFFSET;
  const samples: number[] = [];
  for (let i = 0; i < 1_000_000; i++) {
    const u = rng.next() * 4294967296;
    xor = (xor ^ u) >>> 0;
    sum = (sum + u) % 4294967296;
    h = mix(h, u);
    if (i % 100_000 === 99_999) samples.push(u);
  }

  // int, range and pick as the rules call them.
  const helpers = createRng(99);
  const ints: number[] = [];
  const ranges: string[] = [];
  const picks: number[] = [];
  for (let i = 0; i < 200; i++) {
    ints.push(helpers.int(5, 6));
    ints.push(helpers.int(2, 3));
    ranges.push(hex(helpers.range(80, 120)));
    ranges.push(hex(helpers.range(-1000, 1000)));
    ranges.push(hex(helpers.range(1, 2.5)));
    picks.push(helpers.pick([0, 1, 2]));
    picks.push(helpers.pick([3, 7]));
  }

  return {
    first,
    million: { seed: millionSeed, count: 1_000_000, xor, sum_mod_2_32: sum, fnv: h, every_100000th: samples },
    helpers: {
      seed: 99,
      order: 'per round: int(5,6), int(2,3), range(80,120), range(-1000,1000), range(1,2.5), pick([0,1,2]), pick([3,7])',
      rounds: 200,
      ints,
      ranges,
      picks,
    },
  };
}

// ---------------------------------------------------------------------------------------------------------------
// 2. Speed: 2000 calls of stepSpeed, covering every branch.

function speedInput(i: number): number {
  if (i < 300) return ACCEL | STEER_NONE; // low gear to its 198 km/h top, then holding it
  if (i < 600) return ACCEL | HIGH | STEER_NONE; // high gear above 160 km/h: 45 km/h/s up to 400
  if (i < 700) return HIGH | STEER_NONE; // coasting in high gear
  if (i < 900) return STEER_NONE; // low gear above its top: overspeed fall
  if (i < 1000) return ACCEL | STEER_NONE; // throttle above the top does not help
  if (i < 1200) return ACCEL | BRAKE | STEER_NONE; // brake beats throttle, then stays at 0
  if (i < 1500) return ACCEL | HIGH | STEER_NONE; // high gear from a standstill: 15 km/h/s below 160
  // A mixed pattern from a fixed integer sequence (no RNG involved).
  const r = (i * 2654435761) >>> 0;
  const pattern = [ACCEL, ACCEL | HIGH, HIGH, 0, ACCEL | BRAKE, BRAKE, ACCEL, ACCEL | HIGH][(r >>> 13) % 8];
  return pattern | steerBits(((r >>> 7) % 3) - 1);
}

function speedSection(): unknown {
  let speed = 0;
  const inputs: number[] = [];
  const speeds: string[] = [];
  for (let i = 0; i < 2000; i++) {
    const byte = speedInput(i);
    const input = decode(byte);
    speed = stepSpeed(speed, gearFor(input), input, DT);
    inputs.push(byte);
    speeds.push(hex(speed));
  }
  return { steps: 2000, dt: hex(DT), start_speed: hex(0), inputs, speeds };
}

// ---------------------------------------------------------------------------------------------------------------
// 3. Sixty seconds with no traffic: speed, fuel and distance. No steering, so the road geometry does not matter.

function noTrafficInput(i: number): number {
  if (i === 1900 || i === 1960) return PAUSE | STEER_NONE;
  if (i < 400) return ACCEL | STEER_NONE;
  if (i < 1500) return ACCEL | HIGH | STEER_NONE;
  if (i < 1700) return HIGH | STEER_NONE;
  if (i < 1800) return BRAKE | STEER_NONE;
  if (i < 2800) return ACCEL | HIGH | STEER_NONE;
  if (i < 3100) return STEER_NONE;
  return ACCEL | HIGH | STEER_NONE;
}

function noTrafficSection(): unknown {
  const seed = 1;
  let s = createGame(seed);
  s = { ...s, spawner: { carGap: Infinity, oilGap: Infinity, fuelGap: Infinity, nextId: s.spawner.nextId } };
  const inputs: number[] = [];
  const speed: string[] = [];
  const fuel: string[] = [];
  const distance: string[] = [];
  const phase: number[] = [];
  for (let i = 0; i < 3600; i++) {
    const byte = noTrafficInput(i);
    s = step(s, decode(byte), DT);
    expect(s.traffic).toHaveLength(0);
    inputs.push(byte);
    speed.push(hex(s.car.speed));
    fuel.push(hex(s.fuel.amount));
    distance.push(hex(s.distance));
    phase.push(PHASES.indexOf(s.phase));
  }
  expect(s.phase).toBe('running');
  return {
    seed,
    ticks: 3600,
    setup: 'createGame(seed), then spawner gaps set to Infinity so nothing spawns',
    inputs,
    speed,
    fuel,
    distance,
    phase,
  };
}

// ---------------------------------------------------------------------------------------------------------------
// 4. Three minutes of the whole game: fixed seed, inputs from a deterministic autopilot plus scripted segments.
// The inputs are recorded, so the GDScript side only replays bytes and never needs this autopilot.

const WORLD_SEED = 20261014;
const WORLD_TICKS = 3 * 60 * 60;
const PAUSE_AT = 600;
const RESUME_AT = 660;
const BRAKE_FROM = 1500;
const BRAKE_TO = 1620;
const WALL_FROM = 3000;
const WALL_TO = 3070;
const COAST_FROM = 3600;
const COAST_TO = 3720;
const NO_CORRECTION_FROM = 1540;
const NO_CORRECTION_TO = 1700;
/** From here on the pilot drives into trucks, to end a game; the next game starts 60 steps after the game over. */
const TRUCK_HUNT_FROM = 9400;
const LOOK_AHEAD = 330;

interface Pilot {
  lane: number;
  waitAtPanel: number;
  /** Games started after the first one. */
  games: number;
}

function laneOfCar(c: TrafficCar): number {
  return laneOf(c.x, c.w);
}

/** Traffic in a lane that the player would meet soon: from LOOK_AHEAD px above the player to just behind it. */
function inWindow(c: TrafficCar, lane: number): boolean {
  return laneOfCar(c) === lane && c.y + c.h > PLAYER.y - LOOK_AHEAD && c.y < PLAYER.y + PLAYER.height + 8;
}

function autopilot(s: GameState, tick: number, pilot: Pilot): number {
  if (s.phase === 'gameOver') return STEER_NONE;
  if (s.phase === 'stageClear') {
    pilot.waitAtPanel += 1;
    return pilot.waitAtPanel === 30 ? CONFIRM | STEER_NONE : STEER_NONE;
  }
  pilot.waitAtPanel = 0;
  if (s.phase === 'paused') return tick === RESUME_AT ? PAUSE | STEER_NONE : STEER_NONE;
  if (tick === PAUSE_AT) return PAUSE | ACCEL | STEER_NONE;

  const car = s.car;
  const here = laneOf(car.x, car.w);
  const truckAhead = (lane: number): boolean => s.traffic.some((c) => c.kind === 'truck' && inWindow(c, lane));
  const fuelAhead = (lane: number): boolean => s.traffic.some((c) => c.kind === 'fuelCar' && inWindow(c, lane));

  // Lane choice: leave a lane with a truck ahead, chase fuel cars when the tank is not full.
  const hunting = tick >= TRUCK_HUNT_FROM && pilot.games === 0;
  const truckLane = [0, 1, 2].find((l) => truckAhead(l));
  if (hunting && truckLane !== undefined) {
    pilot.lane = truckLane;
  } else if (truckAhead(pilot.lane)) {
    const options = [pilot.lane - 1, pilot.lane + 1, pilot.lane - 2, pilot.lane + 2].filter(
      (l) => l >= 0 && l < 3 && !truckAhead(l),
    );
    if (options.length > 0) pilot.lane = options[0];
  } else if (s.fuel.amount < 90) {
    for (const l of [here, here - 1, here + 1, here - 2, here + 2]) {
      if (l >= 0 && l < 3 && fuelAhead(l) && !truckAhead(l)) {
        pilot.lane = l;
        break;
      }
    }
  }

  let steer = 0;
  if (car.slideVx !== 0) {
    // Steering into the slide recovers it, except in the window where the pilot lets it slide.
    const correcting = tick < NO_CORRECTION_FROM || tick >= NO_CORRECTION_TO;
    steer = correcting ? Math.sign(car.slideVx) : 0;
  } else {
    const targetX = laneX(pilot.lane, car.w);
    if (car.x < targetX - 1) steer = 1;
    else if (car.x > targetX + 1) steer = -1;
  }
  if (tick >= WALL_FROM && tick < WALL_TO) steer = -1;

  let byte = ACCEL;
  if (car.speed >= 190) byte |= HIGH;
  if (tick >= BRAKE_FROM && tick < BRAKE_TO) byte = ACCEL | BRAKE;
  if (tick >= COAST_FROM && tick < COAST_TO) byte = 0;
  return byte | steerBits(steer);
}

function worldSection(): { section: unknown; counts: Record<string, number> } {
  const pilot: Pilot = { lane: 1, waitAtPanel: 0, games: 0 };
  const restarts: { tick: number; seed: number }[] = [];
  let s = createGame(WORLD_SEED);
  let restartSeed = WORLD_SEED;
  let gameOverTicks = 0;

  const columns = {
    input: [] as number[],
    phase: [] as number[],
    stage: [] as number[],
    x: [] as string[],
    speed: [] as string[],
    fuel: [] as string[],
    distance: [] as string[],
    score: [] as number[],
    events: [] as number[],
    traffic_count: [] as number[],
    next_id: [] as number[],
    traffic_hash: [] as number[],
    traffic_y_sum: [] as string[],
    player_hash: [] as number[],
  };
  const snapshots: unknown[] = [];
  const counts: Record<string, number> = {};
  const seen = new Set<string>();
  const changing = new Set<string>();

  for (let tick = 0; tick < WORLD_TICKS; tick++) {
    // A game over is followed, 60 steps later, by a new game with the next seed and the session high score,
    // as GameScene does when Enter is pressed.
    if (s.phase === 'gameOver') {
      gameOverTicks += 1;
      if (gameOverTicks === 60) {
        restartSeed += 1;
        restarts.push({ tick, seed: restartSeed });
        s = createGame(restartSeed, s.highScore);
        pilot.lane = 1;
        pilot.games += 1;
        gameOverTicks = 0;
      }
    }

    const byte = autopilot(s, tick, pilot);
    s = step(s, decode(byte), DT);
    for (const event of s.events) counts[event] = (counts[event] ?? 0) + 1;
    for (const c of s.traffic) {
      const key = `${restartSeed}:${s.stage}:${c.id}`;
      if (!seen.has(key)) {
        seen.add(key);
        counts[`spawned_${c.kind}`] = (counts[`spawned_${c.kind}`] ?? 0) + 1;
      }
      if (c.targetX !== null && !changing.has(key)) {
        changing.add(key);
        const towardPlayer = laneOf(c.targetX, c.w) === laneOf(s.car.x, s.car.w);
        const name = `lane_change_${c.kind}${towardPlayer ? '_into_player_lane' : ''}`;
        counts[name] = (counts[name] ?? 0) + 1;
      }
      if (c.targetX === null) changing.delete(key);
    }

    columns.input.push(byte);
    columns.phase.push(PHASES.indexOf(s.phase));
    columns.stage.push(s.stage);
    columns.x.push(hex(s.car.x));
    columns.speed.push(hex(s.car.speed));
    columns.fuel.push(hex(s.fuel.amount));
    columns.distance.push(hex(s.distance));
    columns.score.push(s.score);
    columns.events.push(eventMask(s.events));
    columns.traffic_count.push(s.traffic.length);
    columns.next_id.push(s.spawner.nextId);
    columns.traffic_hash.push(trafficHash(s.traffic));
    columns.traffic_y_sum.push(hex(s.traffic.reduce((sum, c) => sum + c.y, 0)));
    columns.player_hash.push(playerHash(s));
    if (tick % 60 === 59) snapshots.push(snapshot(tick, s));
  }

  return {
    section: {
      seed: WORLD_SEED,
      ticks: WORLD_TICKS,
      restarts,
      script: {
        pause_at: PAUSE_AT,
        resume_at: RESUME_AT,
        brake: [BRAKE_FROM, BRAKE_TO],
        wall: [WALL_FROM, WALL_TO],
        coast: [COAST_FROM, COAST_TO],
        no_skid_correction: [NO_CORRECTION_FROM, NO_CORRECTION_TO],
        truck_hunt_from: TRUCK_HUNT_FROM,
      },
      columns,
      snapshots,
    },
    counts,
  };
}

describe('Phaser golden traces', () => {
  it('writes tests/golden/phaser_golden.json', () => {
    const world = worldSection();
    const golden = {
      format: 1,
      source_commit: '0a0841f',
      generator: 'tools/gen_golden/phaser_golden.test.ts',
      dt: hex(DT),
      codes: { kinds: KINDS, phases: PHASES, events: EVENTS },
      input_bits: { accel: ACCEL, brake: BRAKE, steer_shift: 2, high_gear: HIGH, pause: PAUSE, confirm: CONFIRM },
      hash: 'FNV-1a over u32 words: h = 2166136261; h = ((h ^ word) * 16777619) mod 2^32; a double is its two LE words',
      rng: rngSection(),
      speed_trace: speedSection(),
      no_traffic_60s: noTrafficSection(),
      world_phaser: world.section,
      world_event_counts: world.counts,
    };

    // The world trace must exercise the rules it is meant to pin down.
    const c = world.counts;
    console.log('world event counts', c);
    for (const event of ['pass', 'bump', 'skid', 'pickup', 'crash', 'stageClear', 'gameOver', 'pause', 'resume']) {
      expect(c[event] ?? 0, event).toBeGreaterThan(0);
    }

    mkdirSync(dirname(OUT), { recursive: true });
    writeFileSync(OUT, `${JSON.stringify(golden)}\n`);
    console.log(`wrote ${OUT}`);
  });
});
