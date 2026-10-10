import { describe, expect, it } from 'vitest';
import { CRASH, FUEL } from '../src/config';
import { applyCrashFuel, chainBonus, collectFuelCar, createFuel, drainFuel } from '../src/game/fuel';
import { createRng } from '../src/game/rng';

describe('drainFuel', () => {
  it('drains 1 unit per second while moving', () => {
    expect(drainFuel(createFuel(), 100, 10).amount).toBeCloseTo(FUEL.max - 10 * FUEL.drainPerSec, 5);
  });

  it('does not drain while stopped', () => {
    expect(drainFuel(createFuel(), 0, 10).amount).toBe(FUEL.max);
  });

  it('never goes below zero', () => {
    expect(drainFuel({ amount: 0.5, chain: 0 }, 100, 10).amount).toBe(0);
  });
});

describe('chain bonus', () => {
  it('climbs 300, 600, 1200 … and caps at 10 000', () => {
    const points: number[] = [];
    let fuel = createFuel();
    for (let i = 0; i < 8; i++) {
      const r = collectFuelCar(fuel);
      points.push(r.points);
      fuel = r.fuel;
    }
    expect(points).toEqual([300, 600, 1200, 2400, 4800, 9600, 10000, 10000]);
  });

  it('chainBonus(index) matches the sequence', () => {
    expect(chainBonus(0)).toBe(300);
    expect(chainBonus(5)).toBe(9600);
    expect(chainBonus(20)).toBe(FUEL.chainCap);
  });
});

describe('collectFuelCar', () => {
  it('refills by the pickup amount, capped at the tank size', () => {
    expect(collectFuelCar({ amount: 50, chain: 0 }).fuel.amount).toBe(50 + FUEL.pickup);
    expect(collectFuelCar({ amount: 95, chain: 0 }).fuel.amount).toBe(FUEL.max);
  });

  it('increments the chain', () => {
    expect(collectFuelCar({ amount: 50, chain: 2 }).fuel.chain).toBe(3);
  });
});

describe('applyCrashFuel', () => {
  it('costs 5 or 6 units and resets the chain', () => {
    const rng = createRng(7);
    for (let i = 0; i < 50; i++) {
      const out = applyCrashFuel({ amount: 80, chain: 4 }, rng);
      const cost = 80 - out.amount;
      expect(cost).toBeGreaterThanOrEqual(CRASH.fuelMin);
      expect(cost).toBeLessThanOrEqual(CRASH.fuelMax);
      expect(out.chain).toBe(0);
    }
  });

  it('never goes below zero', () => {
    expect(applyCrashFuel({ amount: 2, chain: 0 }, createRng(1)).amount).toBe(0);
  });
});
