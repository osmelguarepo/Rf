import { describe, expect, it } from 'vitest';
import { CRASH, PLAYER, ROAD, SPEED, STEER } from '../src/config';
import { applyCrash, createCar, startSkid, stepGear, stepLateral, stepSpeed } from '../src/game/car';
import { NO_INPUT, type GameInput } from '../src/game/types';

const DT = 1 / 60;
const input = (over: Partial<GameInput> = {}): GameInput => ({ ...NO_INPUT, ...over });

describe('stepSpeed', () => {
  it('accelerates in low gear and stops at 198 km/h', () => {
    let speed = 0;
    for (let i = 0; i < 60 * 20; i++) speed = stepSpeed(speed, 'low', input({ accel: true }), DT);
    expect(speed).toBe(SPEED.lowGearTop);
  });

  it('high gear raises the top speed to 400 km/h', () => {
    let speed = 0;
    for (let i = 0; i < 60 * 30; i++) speed = stepSpeed(speed, 'high', input({ accel: true }), DT);
    expect(speed).toBe(SPEED.highGearTop);
  });

  it('high gear is slower than low gear from a standstill', () => {
    const low = stepSpeed(0, 'low', input({ accel: true }), 1);
    const high = stepSpeed(0, 'high', input({ accel: true }), 1);
    expect(high).toBeLessThan(low);
  });

  it('coasts down with drag when there is no input', () => {
    expect(stepSpeed(100, 'low', NO_INPUT, 1)).toBe(100 - SPEED.drag);
  });

  it('brake beats accelerate and never goes below zero', () => {
    expect(stepSpeed(10, 'low', input({ accel: true, brake: true }), 1)).toBe(0);
  });

  it('drops straight to the low gear top speed when switching down from high gear', () => {
    expect(stepSpeed(350, 'low', NO_INPUT, DT)).toBe(SPEED.lowGearTop);
  });
});

describe('stepGear', () => {
  it('A selects high gear and B selects low gear', () => {
    expect(stepGear('low', input({ highGearPressed: true }))).toBe('high');
    expect(stepGear('high', input({ lowGearPressed: true }))).toBe('low');
  });

  it('keeps the current gear when neither button is pressed', () => {
    expect(stepGear('high', NO_INPUT)).toBe('high');
    expect(stepGear('low', NO_INPUT)).toBe('low');
  });
});

describe('stepLateral', () => {
  it('steers at a rate that falls with speed', () => {
    const car = { ...createCar(167), speed: 100 };
    const result = stepLateral(car, input({ steer: 1 }), DT);
    expect(result.x).toBeCloseTo(167 + ((STEER.baseRate - STEER.perKmh * 100) * DT), 5);
  });

  it('clamps the car to the road without a spin when not skidding', () => {
    const car = { ...createCar(ROAD.left), speed: 100 };
    const result = stepLateral(car, input({ steer: -1 }), DT);
    expect(result.x).toBe(ROAD.left);
    expect(result.spunOut).toBe(false);
  });

  it('reaching the roadside while sliding is a spin-out', () => {
    const sliding = startSkid({ ...createCar(ROAD.left), speed: 100 }, -1);
    const result = stepLateral(sliding, input(), DT);
    expect(result.x).toBe(ROAD.left);
    expect(result.spunOut).toBe(true);
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

  it('steering against the slide or not steering leaves the slide speed unchanged', () => {
    const skid = startSkid({ ...createCar(167), speed: 100 }, 1);
    expect(stepLateral(skid, input({ steer: -1 }), 0.1).slideVx).toBe(skid.slideVx);
    expect(stepLateral(skid, input(), 0.1).slideVx).toBe(skid.slideVx);
  });

  it('an uncorrected skid from the centre lane spins out within 2 seconds', () => {
    let car = startSkid({ ...createCar(167), speed: 100 }, -1);
    let spun = false;
    for (let i = 0; i < 60 * 2 && !spun; i++) {
      const r = stepLateral(car, input(), DT);
      spun = r.spunOut;
      car = { ...car, x: r.x, slideVx: r.slideVx };
    }
    expect(spun).toBe(true);
  });
});

describe('applyCrash', () => {
  it('drops speed to 30 % and starts invulnerability', () => {
    const crashed = applyCrash({ ...createCar(167), speed: 200, slideVx: 50 });
    expect(crashed.speed).toBeCloseTo(200 * CRASH.speedFactor, 5);
    expect(crashed.invulnerable).toBe(CRASH.invulnerableSec);
    expect(crashed.slideVx).toBe(0);
  });

  it('keeps the car the player-sized rectangle', () => {
    const car = createCar(167);
    expect(car.w).toBe(PLAYER.width);
    expect(car.h).toBe(PLAYER.height);
  });
});
