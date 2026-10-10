import { CRASH, FUEL } from '../config';
import type { Rng } from './rng';

export interface FuelState {
  /** Units left, 0..FUEL.max. */
  amount: number;
}

export function createFuel(): FuelState {
  return { amount: FUEL.max };
}

/** Drains fuel while the run is active, whether the car is moving or not. Never goes below 0. */
export function drainFuel(fuel: FuelState, dt: number): FuelState {
  return { amount: Math.max(0, fuel.amount - FUEL.drainPerSec * dt) };
}

/** Fuel-car pickup: refills (capped at the tank size) and pays a flat 1000 points. */
export function collectFuelCar(fuel: FuelState): { fuel: FuelState; points: number } {
  return {
    fuel: { amount: Math.min(FUEL.max, fuel.amount + FUEL.pickup) },
    points: FUEL.fuelCarPoints,
  };
}

/** Roadside crash cost: a whole number of units, from CRASH.fuelMin to CRASH.fuelMax inclusive. */
export function applyCrashFuel(fuel: FuelState, rng: Rng): FuelState {
  const cost = rng.int(CRASH.fuelMin, CRASH.fuelMax);
  return { amount: Math.max(0, fuel.amount - cost) };
}

export function isEmpty(fuel: FuelState): boolean {
  return fuel.amount <= 0;
}
