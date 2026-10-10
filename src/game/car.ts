import { CRASH, PLAYER, ROAD, SPEED, STEER } from '../config';
import type { Gear, GameInput } from './types';

export interface CarState {
  /** Left edge in logical pixels. */
  x: number;
  /** Top edge in logical pixels (fixed). */
  y: number;
  w: number;
  h: number;
  /** km/h. */
  speed: number;
  gear: Gear;
  /** Lateral slide speed in px/s. 0 when not skidding. */
  slideVx: number;
  /** Seconds of invulnerability left after a crash. */
  invulnerable: number;
}

export function createCar(startX: number): CarState {
  return {
    x: startX,
    y: PLAYER.y,
    w: PLAYER.width,
    h: PLAYER.height,
    speed: 0,
    gear: 'low',
    slideVx: 0,
    invulnerable: 0,
  };
}

export function isSkidding(car: CarState): boolean {
  return car.slideVx !== 0;
}

/** A button selects high gear, B selects low gear. The choice sticks until the other button is pressed. */
export function stepGear(gear: Gear, input: GameInput): Gear {
  if (input.highGearPressed) return 'high';
  if (input.lowGearPressed) return 'low';
  return gear;
}

/** Top speed for a gear, in km/h. */
export function gearTopSpeed(gear: Gear): number {
  return gear === 'low' ? SPEED.lowGearTop : SPEED.highGearTop;
}

/** Advances speed (km/h) by one step. Brake beats accelerate; with no input the car coasts down. */
export function stepSpeed(speed: number, gear: Gear, input: GameInput, dt: number): number {
  const top = gearTopSpeed(gear);
  const accel = gear === 'low' ? SPEED.lowGearAccel : SPEED.highGearAccel;

  let next = speed;
  if (input.brake) next -= SPEED.brake * dt;
  else if (input.accel) next += accel * dt;
  else next -= SPEED.drag * dt;

  return Math.min(Math.max(next, 0), top);
}

/** Lateral steering rate in px/s. Slower at high speed. */
export function steerRate(speed: number): number {
  return STEER.baseRate - STEER.perKmh * speed;
}

/** Starts a skid. `direction` is -1 (slide left) or 1 (slide right). */
export function startSkid(car: CarState, direction: -1 | 1): CarState {
  return { ...car, slideVx: direction * STEER.skidSpeed };
}

export interface LateralResult {
  x: number;
  slideVx: number;
  /** True when the car reached the roadside while sliding. This is a spin-out crash. */
  spunOut: boolean;
}

/**
 * Moves the car sideways for one step.
 *
 * Normal driving: steering moves the car at a speed-dependent rate, clamped to the road.
 *
 * Skidding: steering does NOT move the car. The slide carries it at a constant speed.
 * Steering into the slide reduces the slide speed at STEER.correctionAccel until it reaches 0 (recovered).
 * Steering against it or not steering leaves the slide unchanged. Reaching the roadside while sliding is a spin-out.
 */
export function stepLateral(car: CarState, input: GameInput, dt: number): LateralResult {
  const minX = ROAD.left;
  const maxX = ROAD.right - car.w;

  if (car.slideVx !== 0) {
    const x = car.x + car.slideVx * dt;
    if (x <= minX || x >= maxX) {
      return { x: Math.min(Math.max(x, minX), maxX), slideVx: 0, spunOut: true };
    }

    let slideVx = car.slideVx;
    const steeringIntoSlide = input.steer !== 0 && Math.sign(input.steer) === Math.sign(slideVx);
    if (steeringIntoSlide) {
      const reduction = STEER.correctionAccel * dt;
      slideVx = Math.abs(slideVx) <= reduction ? 0 : slideVx - Math.sign(slideVx) * reduction;
    }
    return { x, slideVx, spunOut: false };
  }

  const x = car.x + input.steer * steerRate(car.speed) * dt;
  return { x: Math.min(Math.max(x, minX), maxX), slideVx: 0, spunOut: false };
}

/** Applies a crash: speed drops, invulnerability starts, and any skid ends. */
export function applyCrash(car: CarState): CarState {
  return {
    ...car,
    speed: car.speed * CRASH.speedFactor,
    slideVx: 0,
    invulnerable: CRASH.invulnerableSec,
  };
}

export function tickInvulnerable(car: CarState, dt: number): CarState {
  return { ...car, invulnerable: Math.max(0, car.invulnerable - dt) };
}
