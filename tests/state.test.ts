import { describe, expect, it } from 'vitest';
import { CRASH, FUEL, PLAYER, SCORE, STAGE } from '../src/config';
import { createGame, step, type GameState } from '../src/game/state';
import { NO_INPUT, type GameInput } from '../src/game/types';
import { laneX, type TrafficCar } from '../src/game/traffic';
import { stageGoal } from '../src/game/stage';

const DT = 1 / 60;
const input = (over: Partial<GameInput> = {}): GameInput => ({ ...NO_INPUT, ...over });

/** A traffic object placed exactly on the player car. Speed 0 so nothing moves relative to the road. */
function onPlayer(kind: TrafficCar['kind'], overrides: Partial<TrafficCar> = {}): TrafficCar {
  const size = kind === 'truck' ? { w: 30, h: 60 } : kind === 'oil' ? { w: 40, h: 24 } : { w: 24, h: 40 };
  return {
    id: 999,
    kind,
    x: 167 - (size.w - PLAYER.width) / 2,
    y: PLAYER.y - (size.h - PLAYER.height) / 2,
    w: size.w,
    h: size.h,
    kmh: 0,
    targetX: null,
    lanesLeft: 0,
    laneTimer: 99,
    passed: false,
    consumed: false,
    struck: false,
    ...overrides,
  };
}

function withTraffic(state: GameState, traffic: TrafficCar[]): GameState {
  return { ...state, traffic };
}

describe('createGame', () => {
  it('starts running on stage 1 with a full tank and the first goal', () => {
    const s = createGame(42);
    expect(s.phase).toBe('running');
    expect(s.stage).toBe(1);
    expect(s.fuel.amount).toBe(FUEL.max);
    expect(s.distance).toBe(0);
    expect(s.goal).toBe(STAGE.firstGoal);
    expect(s.car.x).toBe(laneX(1, PLAYER.width));
  });
});

describe('pause', () => {
  it('Esc/P toggles pause, and nothing moves while paused', () => {
    let s = step(createGame(1), input({ accel: true }), DT);
    s = step(s, input({ pausePressed: true }), DT);
    expect(s.phase).toBe('paused');

    const frozen = s.distance;
    const frozenFuel = s.fuel.amount;
    for (let i = 0; i < 120; i++) s = step(s, input({ accel: true }), DT);
    expect(s.phase).toBe('paused');
    expect(s.distance).toBe(frozen);
    expect(s.fuel.amount).toBe(frozenFuel);

    s = step(s, input({ pausePressed: true }), DT);
    expect(s.phase).toBe('running');
  });
});

describe('fuel and game over', () => {
  it('an empty tank ends the run', () => {
    const base = createGame(1);
    const s = step({ ...base, fuel: { amount: 0.001 }, car: { ...base.car, speed: 100 } }, NO_INPUT, DT);
    expect(s.phase).toBe('gameOver');
    expect(s.events).toContain('gameOver');
  });

  it('fuel drains even when the car is stopped', () => {
    const base = createGame(1);
    const s = step(base, NO_INPUT, 1);
    expect(s.fuel.amount).toBeCloseTo(FUEL.max - FUEL.drainPerSec, 5);
  });

  it('touching a truck ends the run', () => {
    const base = createGame(1);
    const s = step(withTraffic(base, [onPlayer('truck')]), NO_INPUT, DT);
    expect(s.phase).toBe('gameOver');
  });
});

describe('bumps and roadside crashes', () => {
  it('a car bump costs no fuel and no speed, and starts a skid away from the car', () => {
    const base = createGame(1);
    // Player is at lane 1 (centre). Put a yellow car on the player's right half, so the push should be left.
    const bumper = onPlayer('yellow', { x: 180 });
    const s = step({ ...base, car: { ...base.car, speed: 150 }, traffic: [bumper] }, input({ accel: true }), DT);

    expect(s.events).toContain('bump');
    expect(s.events).not.toContain('crash');
    expect(s.fuel.amount).toBeCloseTo(FUEL.max - FUEL.drainPerSec * DT, 5);
    expect(s.car.speed).toBeGreaterThan(149);
    expect(s.car.slideVx).toBeLessThan(0);
    expect(s.car.invulnerable).toBeGreaterThan(0);
    expect(s.phase).toBe('running');
  });

  it('the same traffic car cannot bump the player twice, even after invulnerability ends', () => {
    const base = createGame(1);
    const car = onPlayer('yellow');
    const first = step({ ...base, traffic: [car] }, NO_INPUT, DT);
    expect(first.events).toContain('bump');
    expect(first.traffic.find((t) => t.id === car.id)?.struck).toBe(true);

    const later = step({ ...first, car: { ...first.car, invulnerable: 0, slideVx: 0 } }, NO_INPUT, DT);
    expect(later.events).not.toContain('bump');
  });

  it('a bump during invulnerability is ignored and does not mark the car as struck', () => {
    const base = createGame(1);
    const car = onPlayer('yellow');
    const s = step({ ...base, car: { ...base.car, invulnerable: 1 }, traffic: [car] }, NO_INPUT, DT);
    expect(s.events).not.toContain('bump');
    expect(s.traffic.find((t) => t.id === car.id)?.struck).toBe(false);
  });

  it('a roadside crash costs 5–6 fuel, drops speed to 30 %, and starts invulnerability', () => {
    const base = createGame(1);
    const s = step({ ...base, car: { ...base.car, x: 60, speed: 100, slideVx: -90 } }, NO_INPUT, DT);
    expect(s.events).toContain('spin');
    expect(s.events).toContain('crash');
    const cost = FUEL.max - s.fuel.amount - FUEL.drainPerSec * DT;
    expect(cost).toBeGreaterThanOrEqual(CRASH.fuelMin - 0.01);
    expect(cost).toBeLessThanOrEqual(CRASH.fuelMax + 0.01);
    expect(s.car.speed).toBeCloseTo(100 * CRASH.speedFactor, 0);
    expect(s.car.invulnerable).toBeGreaterThan(0);
    expect(s.phase).toBe('running');
  });
});

describe('oil and skids', () => {
  it('driving onto oil starts a skid exactly once', () => {
    const base = createGame(5);
    const first = step({ ...base, traffic: [onPlayer('oil')] }, NO_INPUT, DT);
    expect(first.events).toContain('skid');
    expect(first.car.slideVx).not.toBe(0);

    const second = step({ ...first, traffic: [onPlayer('oil', { id: 1000 })] }, NO_INPUT, DT);
    expect(second.events).not.toContain('skid');
  });
});

describe('fuel pickups', () => {
  it('a fuel car refills by 10 and pays a flat 1000 points', () => {
    const base = createGame(1);
    const s = step({ ...base, fuel: { amount: 50 }, traffic: [onPlayer('fuelCar')] }, NO_INPUT, DT);
    expect(s.events).toContain('pickup');
    expect(s.score).toBe(1000);
    expect(s.fuel.amount).toBeCloseTo(50 + FUEL.pickup - DT * FUEL.drainPerSec, 5);
  });
});

describe('scoring', () => {
  it('passing a car scores 50 points', () => {
    const base = createGame(1);
    const passing: TrafficCar = {
      ...onPlayer('yellow'),
      id: 500,
      x: laneX(0, 24),
      y: PLAYER.y + PLAYER.height - 0.1,
      kmh: 0,
    };
    const s = step({ ...base, car: { ...base.car, speed: 100 }, traffic: [passing] }, NO_INPUT, DT);
    expect(s.events).toContain('pass');
    expect(s.score).toBe(SCORE.perPassedCar);
  });
});

describe('stages', () => {
  it('reaching the goal enters stage clear and pays 30 points per whole fuel unit', () => {
    const base = createGame(1);
    const s = step(
      { ...base, distance: base.goal - 0.001, car: { ...base.car, speed: 100 }, fuel: { amount: 40.9 } },
      NO_INPUT,
      DT,
    );
    expect(s.phase).toBe('stageClear');
    expect(s.events).toContain('stageClear');
    expect(s.score).toBe(Math.floor(40.9 - DT) * SCORE.stageClearPerFuel);
  });

  it('confirm at stage clear starts stage 2 with a longer goal, an empty road and a full tank', () => {
    const base = createGame(1);
    const cleared = { ...base, phase: 'stageClear' as const, traffic: [onPlayer('yellow')], fuel: { amount: 12 } };
    const next = step(cleared, input({ confirmPressed: true }), DT);
    expect(next.phase).toBe('running');
    expect(next.stage).toBe(2);
    expect(next.goal).toBe(STAGE.firstGoal + STAGE.goalStep);
    expect(next.distance).toBe(0);
    expect(next.traffic).toHaveLength(0);
    expect(next.fuel.amount).toBe(FUEL.max);
  });

  it('the goal loops after four stages (24 000, 28 000, 32 000, 36 000, then 24 000)', () => {
    expect([1, 2, 3, 4, 5].map(stageGoal)).toEqual([24000, 28000, 32000, 36000, 24000]);
  });
});

describe('determinism', () => {
  it('the same seed and the same inputs produce the same game', () => {
    const steerCycle = [-1, 0, 1] as const;
    const script = (i: number): GameInput =>
      input({ accel: true, steer: steerCycle[Math.floor(i / 90) % 3] });

    const run = (seed: number): GameState => {
      let s = createGame(seed);
      for (let i = 0; i < 60 * 40; i++) s = step(s, script(i), DT);
      return s;
    };

    const a = run(2024);
    const b = run(2024);
    expect(a.score).toBe(b.score);
    expect(a.distance).toBe(b.distance);
    expect(a.car).toEqual(b.car);
    expect(a.traffic).toEqual(b.traffic);
  });
});
