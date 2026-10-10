import { describe, expect, it } from 'vitest';
import { CRASH, FUEL } from '../src/config';
import { applyCrashFuel, collectFuelCar, createFuel, drainFuel } from '../src/game/fuel';
import { createRng } from '../src/game/rng';

describe('drainFuel', () => {
  it('drains 1 unit per second', () => {
    expect(drainFuel(createFuel(), 10).amount).toBeCloseTo(FUEL.max - 10 * FUEL.drainPerSec, 5);
  });

  it('never goes below zero', () => {
    expect(drainFuel({ amount: 0.5 }, 10).amount).toBe(0);
  });
});

describe('collectFuelCar', () => {
  it('refills by the pickup amount, capped at the tank size', () => {
    expect(collectFuelCar({ amount: 50 }).fuel.amount).toBe(50 + FUEL.pickup);
    expect(collectFuelCar({ amount: 95 }).fuel.amount).toBe(FUEL.max);
  });

  it('pays a flat 1000 points every time, with no chain', () => {
    let fuel = createFuel();
    for (let i = 0; i < 4; i++) {
      const r = collectFuelCar(fuel);
      expect(r.points).toBe(1000);
      fuel = r.fuel;
    }
  });
});

describe('applyCrashFuel', () => {
  it('costs 5 or 6 units', () => {
    const rng = createRng(7);
    for (let i = 0; i < 50; i++) {
      const cost = 80 - applyCrashFuel({ amount: 80 }, rng).amount;
      expect(cost).toBeGreaterThanOrEqual(CRASH.fuelMin);
      expect(cost).toBeLessThanOrEqual(CRASH.fuelMax);
    }
  });

  it('never goes below zero', () => {
    expect(applyCrashFuel({ amount: 2 }, createRng(1)).amount).toBe(0);
  });
});
