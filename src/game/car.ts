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
  /** Seconds of invulnerability left after a crash or bump. */
  invulnerable: number;
}

export interface LateralResult {
  x: number;
  slideVx: number;
  /** True when the car reached the roadside. The car crashes, whether or not it was sliding. */
  hitRoadside: boolean;
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

/** Gear is held, not toggled: the car is in high gear only while A (X) is held. */
export function gearFor(input: GameInput): Gear {
  return input.highGear ? 'high' : 'low';
}

/** Top speed for a gear, in km/h. */
export function gearTopSpeed(gear: Gear): number {
  return gear === 'low' ? SPEED.lowGearTop : SPEED.highGearTop;
}

/**
 * Advances speed (km/h) by one step.
 * Brake beats everything. Above the gear's top speed the car falls back at overspeedFall.
 * Otherwise the throttle accelerates (high gear is slow below 160 km/h), and with no throttle the car coasts.
 */
export function stepSpeed(speed: number, gear: Gear, input: GameInput, dt: number): number {
  const top = gearTopSpeed(gear);

  if (input.brake) return Math.max(0, speed - SPEED.brake * dt);
  if (speed > top) return Math.max(top, speed - SPEED.overspeedFall * dt);
  if (input.accel) {
    const accel =
      gear === 'low'
        ? SPEED.lowGearAccel
        : speed < SPEED.highGearSlowBelow
          ? SPEED.highGearSlowAccel
          : SPEED.highGearAccel;
    return Math.min(top, speed + accel * dt);
  }
  return Math.max(0, speed - SPEED.drag * dt);
}

/** Lateral steering rate in px/s. Zero while stopped, full rate from 30 km/h, slower at high speed. */
export function steerRate(speed: number): number {
  if (speed <= 0) return 0;
  const full = Math.min(1, speed / STEER.steerFullAtKmh);
  return (STEER.steerBase - STEER.steerPerKmh * speed) * full;
}

/** Starts a skid. `direction` is -1 (slide left) or 1 (slide right). */
export function startSkid(car: CarState, direction: -1 | 1): CarState {
  return { ...car, slideVx: direction * STEER.skidSpeed };
}

/**
 * Moves the car sideways for one step.
 *
 * Normal driving: steering moves the car at a speed-dependent rate.
 *
 * Skidding: steering does NOT move the car. The slide carries it at constant speed.
 * Steering into the slide reduces the slide speed at STEER.correctionAccel until it reaches 0 (recovered).
 * Steering against it, or not steering, leaves the slide unchanged.
 *
 * Either way, moving past the road edge reports hitRoadside. The car is held at the edge for rendering.
 */
export function stepLateral(car: CarState, input: GameInput, dt: number): LateralResult {
  const minX = ROAD.left;
  const maxX = ROAD.right - car.w;

  if (car.slideVx !== 0) {
    const raw = car.x + car.slideVx * dt;
    const hitRoadside = raw < minX || raw > maxX;

    let slideVx = car.slideVx;
    const steeringIntoSlide = input.steer !== 0 && Math.sign(input.steer) === Math.sign(slideVx);
    if (steeringIntoSlide && !hitRoadside) {
      const reduction = STEER.correctionAccel * dt;
      slideVx = Math.abs(slideVx) <= reduction ? 0 : slideVx - Math.sign(slideVx) * reduction;
    }
    if (hitRoadside) slideVx = 0;
    return { x: Math.min(Math.max(raw, minX), maxX), slideVx, hitRoadside };
  }

  const raw = car.x + input.steer * steerRate(car.speed) * dt;
  return { x: Math.min(Math.max(raw, minX), maxX), slideVx: 0, hitRoadside: raw < minX || raw > maxX };
}

/** Roadside crash: speed drops, the skid ends, and invulnerability starts. Fuel is handled by the caller. */
export function applyCrash(car: CarState): CarState {
  return {
    ...car,
    speed: car.speed * CRASH.speedFactor,
    slideVx: 0,
    invulnerable: CRASH.invulnerableSec,
  };
}

/** Car-on-car bump: no speed or fuel penalty. It starts a skid away from the other car, and invulnerability starts. */
export function applyBump(car: CarState, direction: -1 | 1): CarState {
  return { ...startSkid(car, direction), invulnerable: CRASH.invulnerableSec };
}

export function tickInvulnerable(car: CarState, dt: number): CarState {
  return { ...car, invulnerable: Math.max(0, car.invulnerable - dt) };
}
