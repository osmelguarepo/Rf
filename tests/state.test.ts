import { describe, expect, it } from 'vitest';
import { CRASH, FUEL, PLAYER, SCORE, STAGE } from '../src/config';
import { createGame, step, type GameState } from '../src/game/state';
import { NO_INPUT, type GameInput } from '../src/game/types';
import { laneX, type TrafficCar } from '../src/game/traffic';

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
    for (let i = 0; i < 120; i++) s = step(s, input({ accel: true }), DT);
    expect(s.phase).toBe('paused');
    expect(s.distance).toBe(frozen);

    s = step(s, input({ pausePressed: true }), DT);
    expect(s.phase).toBe('running');
  });
});

describe('fuel and game over', () => {
  it('an empty tank ends the run', () => {
    const base = createGame(1);
    const s = step({ ...base, fuel: { amount: 0.001, chain: 0 }, car: { ...base.car, speed: 100 } }, NO_INPUT, DT);
    expect(s.phase).toBe('gameOver');
    expect(s.events).toContain('gameOver');
  });

  it('touching a truck ends the run', () => {
    const base = createGame(1);
    const s = step(withTraffic(base, [onPlayer('truck')]), NO_INPUT, DT);
    expect(s.phase).toBe('gameOver');
  });
});

describe('crashes', () => {
  it('a car collision costs 5–6 fuel, slows the car, and grants invulnerability (not game over)', () => {
    const base = createGame(1);
    const s = step({ ...base, car: { ...base.car, speed: 150 } }, input({ accel: true }), DT);
    const before = base.fuel.amount;
    const crashed = step({ ...base, car: { ...base.car, speed: 150 }, traffic: [onPlayer('yellow')] }, input({ accel: true }), DT);

    expect(crashed.phase).toBe('running');
    expect(crashed.events).toContain('crash');
    expect(before - crashed.fuel.amount).toBeGreaterThanOrEqual(CRASH.fuelMin - 0.1);
    expect(before - crashed.fuel.amount).toBeLessThanOrEqual(CRASH.fuelMax + 0.1);
    expect(crashed.car.invulnerable).toBeGreaterThan(0);
    expect(crashed.car.speed).toBeLessThan(150);
    expect(s.phase).toBe('running');
  });

  it('the same traffic car cannot crash the player twice, even after invulnerability ends', () => {
    const base = createGame(1);
    const car = onPlayer('yellow');
    const first = step({ ...base, traffic: [car] }, NO_INPUT, DT);
    expect(first.events).toContain('crash');
    expect(first.traffic.find((t) => t.id === car.id)?.struck).toBe(true);

    const later = step({ ...first, car: { ...first.car, invulnerable: 0 } }, NO_INPUT, DT);
    expect(later.events).not.toContain('crash');
  });

  it('invulnerability stops a second car hit from double-counting', () => {
    const base = createGame(1);
    const once = step({ ...base, traffic: [onPlayer('yellow')] }, NO_INPUT, DT);
    const twice = step({ ...once, traffic: [onPlayer('yellow', { id: 1000 })] }, NO_INPUT, DT);
    expect(twice.events.filter((e) => e === 'crash')).toHaveLength(0);
    expect(twice.fuel.amount).toBeCloseTo(once.fuel.amount, 5);
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

  it('a skid into the roadside is a spin-out crash', () => {
    const base = createGame(1);
    const leftEdge = { ...base.car, x: 60, speed: 100, slideVx: -90 };
    const s = step({ ...base, car: leftEdge }, NO_INPUT, DT);
    expect(s.events).toContain('spin');
    expect(s.events).toContain('crash');
  });
});

describe('fuel pickups', () => {
  it('a fuel car refills and scores the first chain bonus of 300', () => {
    const base = createGame(1);
    const s = step(
      { ...base, fuel: { amount: 50, chain: 0 }, traffic: [onPlayer('fuelCar')] },
      NO_INPUT,
      DT,
    );
    expect(s.events).toContain('pickup');
    expect(s.score).toBe(300);
    expect(s.fuel.amount).toBeGreaterThan(50 + FUEL.pickup - 0.1);
  });
});

describe('scoring', () => {
  it('passing a car scores 50 points', () => {
    const base = createGame(1);
    const passing = {
      id: 500,
      kind: 'yellow' as const,
      x: laneX(0, 24),
      y: PLAYER.y + PLAYER.height - 0.1,
      w: 24,
      h: 40,
      kmh: 0,
      targetX: null,
      lanesLeft: 0,
      laneTimer: 99,
      passed: false,
      consumed: false,
      struck: false,
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
      { ...base, distance: base.goal - 0.001, car: { ...base.car, speed: 100 }, fuel: { amount: 40.9, chain: 0 } },
      NO_INPUT,
      DT,
    );
    expect(s.phase).toBe('stageClear');
    expect(s.events).toContain('stageClear');
    expect(s.score).toBe(Math.floor(40.9 - DT) * SCORE.stageClearPerFuel);
  });

  it('confirm at stage clear starts stage 2 with a longer goal and an empty road', () => {
    const base = createGame(1);
    const cleared = { ...base, phase: 'stageClear' as const, traffic: [onPlayer('yellow')] };
    const next = step(cleared, input({ confirmPressed: true }), DT);
    expect(next.phase).toBe('running');
    expect(next.stage).toBe(2);
    expect(next.goal).toBe(STAGE.firstGoal + STAGE.goalStep);
    expect(next.distance).toBe(0);
    expect(next.traffic).toHaveLength(0);
  });
});

describe('determinism', () => {
  it('the same seed and the same inputs produce the same game', () => {
    const steerCycle = [-1, 0, 1] as const;
    const script = (i: number): GameInput => input({ accel: true, steer: steerCycle[Math.floor(i / 90) % 3] });

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
