import { CRASH, FUEL } from '../config';
import type { Rng } from './rng';

export interface FuelState {
  /** Units left, 0..FUEL.max. */
  amount: number;
  /** Consecutive fuel-car catches since the last crash. Drives the chain bonus. */
  chain: number;
}

export function createFuel(): FuelState {
  return { amount: FUEL.max, chain: 0 };
}

/** Drains fuel while moving. Never goes below 0. */
export function drainFuel(fuel: FuelState, speed: number, dt: number): FuelState {
  if (speed <= 0) return fuel;
  return { ...fuel, amount: Math.max(0, fuel.amount - FUEL.drainPerSec * dt) };
}

/** Points for the n-th consecutive catch (0-based): 300, 600, 1200, ... capped at 10 000. */
export function chainBonus(index: number): number {
  return Math.min(FUEL.chainBase * 2 ** index, FUEL.chainCap);
}

/** Fuel-car pickup: refills (capped) and returns the chain bonus earned. */
export function collectFuelCar(fuel: FuelState): { fuel: FuelState; points: number } {
  const points = chainBonus(fuel.chain);
  return {
    fuel: {
      amount: Math.min(FUEL.max, fuel.amount + FUEL.pickup),
      chain: fuel.chain + 1,
    },
    points,
  };
}

/** Crash cost: a whole number of units, from CRASH.fuelMin to CRASH.fuelMax inclusive. Resets the chain. */
export function applyCrashFuel(fuel: FuelState, rng: Rng): FuelState {
  const cost = rng.int(CRASH.fuelMin, CRASH.fuelMax);
  return { amount: Math.max(0, fuel.amount - cost), chain: 0 };
}

export function isEmpty(fuel: FuelState): boolean {
  return fuel.amount <= 0;
}
