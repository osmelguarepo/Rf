import { describe, expect, it } from 'vitest';
import { CRASH, PLAYER, ROAD, SPEED, STEER } from '../src/config';
import { applyBump, applyCrash, createCar, gearFor, startSkid, stepLateral, stepSpeed, steerRate } from '../src/game/car';
import { NO_INPUT, type GameInput } from '../src/game/types';

const DT = 1 / 60;
const input = (over: Partial<GameInput> = {}): GameInput => ({ ...NO_INPUT, ...over });

function run(speed0: number, gearInput: Partial<GameInput>, seconds: number): number {
  let speed = speed0;
  const steps = Math.round(seconds / DT);
  for (let i = 0; i < steps; i++) speed = stepSpeed(speed, gearFor(input(gearInput)), input(gearInput), DT);
  return speed;
}

describe('gear', () => {
  it('is high only while A (X) is held, low otherwise', () => {
    expect(gearFor(input({ highGear: true }))).toBe('high');
    expect(gearFor(input())).toBe('low');
  });
});

describe('stepSpeed', () => {
  it('low gear accelerates with the throttle and stops at 198 km/h', () => {
    expect(run(0, { accel: true }, 20)).toBe(SPEED.lowGearTop);
  });

  it('high gear reaches 400 km/h', () => {
    expect(run(0, { accel: true, highGear: true }, 40)).toBe(SPEED.highGearTop);
  });

  it('high gear is slow to start below 160 km/h, then faster', () => {
    const slowStart = stepSpeed(0, 'high', input({ accel: true, highGear: true }), 1);
    expect(slowStart).toBeCloseTo(SPEED.highGearSlowAccel, 5);
    const fast = stepSpeed(200, 'high', input({ accel: true, highGear: true }), 1);
    expect(fast).toBeCloseTo(200 + SPEED.highGearAccel, 5);
  });

  it('with no throttle the car coasts down with drag', () => {
    expect(stepSpeed(100, 'low', NO_INPUT, 1)).toBe(100 - SPEED.drag);
  });

  it('brake beats throttle and never goes below zero', () => {
    expect(stepSpeed(10, 'low', input({ accel: true, brake: true }), 1)).toBe(0);
  });

  it('above the gear top the car falls back at overspeedFall, not instantly', () => {
    expect(stepSpeed(350, 'low', NO_INPUT, 1)).toBeCloseTo(350 - SPEED.overspeedFall, 5);
  });

  it('holding the throttle above the gear top does not accelerate further', () => {
    expect(stepSpeed(SPEED.lowGearTop + 5, 'low', input({ accel: true }), DT)).toBeLessThan(SPEED.lowGearTop + 5);
  });
});

describe('steerRate', () => {
  it('is zero while stopped and full from 30 km/h', () => {
    expect(steerRate(0)).toBe(0);
    expect(steerRate(STEER.steerFullAtKmh)).toBeCloseTo(STEER.steerBase - STEER.steerPerKmh * STEER.steerFullAtKmh, 9);
  });

  it('is about 150 px/s at 198 km/h and 130 px/s at 400 km/h', () => {
    expect(steerRate(198)).toBeCloseTo(150.2, 1);
    expect(steerRate(400)).toBeCloseTo(130, 5);
  });
});

describe('stepLateral', () => {
  it('steers at the speed-dependent rate', () => {
    const car = { ...createCar(167), speed: 198 };
    const result = stepLateral(car, input({ steer: 1 }), DT);
    expect(result.x).toBeCloseTo(167 + steerRate(198) * DT, 5);
    expect(result.hitRoadside).toBe(false);
  });

  it('steering into the barrier reports a roadside hit', () => {
    const car = { ...createCar(ROAD.left), speed: 100 };
    const result = stepLateral(car, input({ steer: -1 }), DT);
    expect(result.hitRoadside).toBe(true);
    expect(result.x).toBe(ROAD.left);
  });

  it('a slide into the roadside reports a roadside hit', () => {
    const sliding = startSkid({ ...createCar(ROAD.left), speed: 100 }, -1);
    const result = stepLateral(sliding, input(), DT);
    expect(result.hitRoadside).toBe(true);
    expect(result.slideVx).toBe(0);
  });

  it('while skidding, steering does not move the car sideways', () => {
    const skid = startSkid({ ...createCar(167), speed: 150 }, 1);
    const r = stepLateral(skid, input({ steer: -1 }), DT);
    expect(r.x).toBeCloseTo(167 + STEER.skidSpeed * DT, 9);
  });

  it('steering into the slide recovers it in about 15 steps (90 px/s at 360 px/s²)', () => {
    let car = startSkid({ ...createCar(167), speed: 0 }, 1);
    let steps = 0;
    while (car.slideVx !== 0 && steps < 600) {
      const r = stepLateral(car, input({ steer: 1 }), DT);
      car = { ...car, x: r.x, slideVx: r.slideVx };
      steps += 1;
    }
    expect(car.slideVx).toBe(0);
    expect(steps).toBeGreaterThanOrEqual(14);
    expect(steps).toBeLessThanOrEqual(16);
  });

  it('steering against the slide, or not steering, leaves the slide speed unchanged', () => {
    const skid = startSkid({ ...createCar(167), speed: 100 }, 1);
    expect(stepLateral(skid, input({ steer: -1 }), 0.1).slideVx).toBe(skid.slideVx);
    expect(stepLateral(skid, input(), 0.1).slideVx).toBe(skid.slideVx);
  });

  it('an uncorrected skid from the centre lane reaches the roadside within 2 seconds', () => {
    let car = startSkid({ ...createCar(167), speed: 100 }, -1);
    let hit = false;
    for (let i = 0; i < 60 * 2 && !hit; i++) {
      const r = stepLateral(car, input(), DT);
      hit = r.hitRoadside;
      car = { ...car, x: r.x, slideVx: r.slideVx };
    }
    expect(hit).toBe(true);
  });
});

describe('crash and bump', () => {
  it('a roadside crash drops speed to 30 % and starts invulnerability', () => {
    const crashed = applyCrash({ ...createCar(167), speed: 200, slideVx: 50 });
    expect(crashed.speed).toBeCloseTo(200 * CRASH.speedFactor, 5);
    expect(crashed.invulnerable).toBe(CRASH.invulnerableSec);
    expect(crashed.slideVx).toBe(0);
  });

  it('a bump keeps speed and starts a skid away from the other car', () => {
    const bumped = applyBump({ ...createCar(167), speed: 150 }, -1);
    expect(bumped.speed).toBe(150);
    expect(bumped.slideVx).toBeLessThan(0);
    expect(bumped.invulnerable).toBe(CRASH.invulnerableSec);
  });

  it('the car keeps the player-sized rectangle', () => {
    const car = createCar(167);
    expect(car.w).toBe(PLAYER.width);
    expect(car.h).toBe(PLAYER.height);
  });
});
