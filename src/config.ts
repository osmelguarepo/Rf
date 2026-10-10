/** Every tunable number for the MVP lives here. Values follow docs/PLAN.md §4. */

export const GAME_TITLE = 'ROAD FIGHTER';

/** Logical canvas size. Phaser scales it to fit the window. */
export const VIEW = { width: 360, height: 640 } as const;

/** Road geometry. Three lanes; the roadside strips outside [left, right] are scenery. */
export const ROAD = {
  left: 60,
  right: 300,
  laneCount: 3,
} as const;
export const LANE_WIDTH = (ROAD.right - ROAD.left) / ROAD.laneCount;

/** Speeds are in km/h. World scroll and relative motion use px/s = kmh * KMH_TO_PX. */
export const KMH_TO_PX = 0.5;

export const SPEED = {
  lowGearTop: 198,
  highGearTop: 400,
  lowGearAccel: 70,
  highGearAccel: 45,
  brake: 120,
  drag: 25,
} as const;

export const PLAYER = {
  width: 26,
  height: 44,
  /** Top edge of the player car, in logical pixels. */
  y: 520,
} as const;

export const STEER = {
  /** Lateral speed in px/s = base - perKmh * speed. */
  baseRate: 220,
  perKmh: 0.4,
  /** Skid: initial lateral slide speed (px/s). Steering does not move the car while sliding. */
  skidSpeed: 90,
  /** Steering into the slide reduces its speed by this much per second (px/s²). Reaching 0 ends the skid. */
  correctionAccel: 360,
  /** Lateral speed used when a lane change happens (px/s). */
  laneChangeSpeed: 120,
} as const;

export const CRASH = {
  /** Speed multiplier left after a crash. */
  speedFactor: 0.3,
  fuelMin: 5,
  fuelMax: 6,
  /** Seconds of invulnerability after a crash. */
  invulnerableSec: 1.5,
} as const;

export const FUEL = {
  max: 100,
  /** Units per second while the car is moving. 100 units ≈ 100 seconds of driving. */
  drainPerSec: 1,
  pickup: 20,
  /** Chain bonus: 300 * 2^index, capped. */
  chainBase: 300,
  chainCap: 10000,
} as const;

export const SCORE = {
  perPassedCar: 50,
  stageClearPerFuel: 30,
} as const;

export const STAGE = {
  firstGoal: 12000,
  goalStep: 4000,
  /** Each stage multiplies spawn intervals by this (fewer, but still random). */
  spawnIntervalScale: 0.9,
  /** Each stage multiplies traffic speeds by this. */
  trafficSpeedScale: 1.05,
} as const;

export const TRAFFIC = {
  car: { width: 24, height: 40 },
  truck: { width: 30, height: 60 },
  oil: { width: 40, height: 24 },
  yellowSpeed: [80, 120] as const,
  redSpeed: [90, 110] as const,
  blueSpeed: [100, 130] as const,
  truckSpeed: 60,
  fuelCarSpeed: 90,
  laneChangeCount: { red: 1, blue: [2, 3] as const },
  /** Seconds between spawns, per type, at stage 1. */
  spawnInterval: {
    yellow: 1.2,
    red: 3,
    blue: 4,
    truck: 6,
    fuelCar: 9,
    oil: 5,
  },
} as const;

export const INVULNERABLE_BLINK_HZ = 10;

/** Fixed simulation step in seconds (60 Hz). */
export const SIM_STEP = 1 / 60;
