/** Every tunable number for the MVP lives here. Values follow docs/PLAN.md §4 and §11. */

export const GAME_TITLE = 'ROAD FIGHTER';

/** Logical playfield size. Phaser scales it to fit the window. */
export const VIEW = { width: 360, height: 640 } as const;

/** Road geometry. Three lanes; the roadside strips outside [left, right] are scenery. */
export const ROAD = {
  left: 60,
  right: 300,
  laneCount: 3,
} as const;
export const LANE_WIDTH = (ROAD.right - ROAD.left) / ROAD.laneCount;

/** Speeds are in km/h. World scroll and relative motion use px/s = kmh × KMH_TO_PX (1:1, see §11). */
export const KMH_TO_PX = 1;

export const SPEED = {
  lowGearTop: 198,
  highGearTop: 400,
  lowGearAccel: 70,
  /** High gear is slow to start: below highGearSlowBelow it accelerates at highGearSlowAccel. */
  highGearSlowBelow: 160,
  highGearSlowAccel: 15,
  highGearAccel: 45,
  brake: 120,
  /** Coasting with no throttle. */
  drag: 25,
  /** Speed above the current gear's top falls at this rate. */
  overspeedFall: 25,
} as const;

export const PLAYER = {
  width: 26,
  height: 44,
  /** Top edge of the player car, in logical pixels. */
  y: 520,
} as const;

export const STEER = {
  /**
   * Lateral speed (px/s) = (steerBase − steerPerKmh × speed) × min(1, speed / steerFullAtKmh).
   * The car cannot steer while stopped.
   */
  steerBase: 170,
  steerPerKmh: 0.1,
  steerFullAtKmh: 30,
  /** Skid: initial lateral slide speed (px/s). Steering does not move the car while sliding. */
  skidSpeed: 90,
  /** Steering into the slide reduces its speed by this much per second (px/s²). Reaching 0 ends the skid. */
  correctionAccel: 360,
  /** Lateral speed used when a lane change happens (px/s). */
  laneChangeSpeed: 120,
} as const;

export const CRASH = {
  /** Speed multiplier left after a roadside crash. */
  speedFactor: 0.3,
  fuelMin: 5,
  fuelMax: 6,
  /** Seconds of invulnerability after a crash or bump. */
  invulnerableSec: 1.5,
} as const;

export const FUEL = {
  max: 100,
  /** Units per second while the run is active, moving or not. 100 units ≈ 100 seconds. */
  drainPerSec: 1,
  /** Fuel car pickup: a small boost. */
  pickup: 10,
  /** Fuel car pickup points (NES value, flat). */
  fuelCarPoints: 1000,
} as const;

export const SCORE = {
  perPassedCar: 50,
  stageClearPerFuel: 30,
} as const;

export const STAGE = {
  /** Road distance (px) for stage 1. Each stage adds goalStep, and the goal loops after goalCycle stages. */
  firstGoal: 24000,
  goalStep: 4000,
  goalCycle: 4,
  /** Each stage multiplies spawn gaps by this. Car gaps never go below minSpawnGap. */
  spawnGapScale: 0.9,
  minSpawnGap: 200,
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
  /** Lane changes: red changes lane once, blue 2–3 times. */
  laneChangeCount: { red: 1, blue: [2, 3] as const },
  /** Car type mix at spawn. Weights need not sum to 1. */
  carTypeWeights: { yellow: 0.6, red: 0.2, blue: 0.1, truck: 0.1 },
  /** Distance (px of road) between spawns, at stage 1. Oil and fuel cars use a jitter range. */
  spawnGap: { car: 350, oil: 4000, fuel: 8000 },
  spawnJitter: { car: 0, oil: 1000, fuel: 2000 },
} as const;

export const INVULNERABLE_BLINK_HZ = 10;

/** Fixed simulation step in seconds (60 Hz). */
export const SIM_STEP = 1 / 60;

/**
 * Sprites: frame names and whole-number draw scales. Visual only: the hitboxes above do not change.
 *
 * Frames come from public/assets/sprites.json, except `truck` and `oil_puddle`, which the sheet does not have and
 * src/render/pixelArt.ts draws in code. Car frames carry a 1 px shadow on the right and bottom (`shadow`), which is
 * left out when a sprite is centred on its hitbox.
 */
export const SPRITE = {
  /** Texture key of public/assets/sprites.png, and cache key of its frame map. */
  atlas: 'sprites',
  /** Road, verge and grass tiles are 8 px, drawn at 4× (32 px). A tile pixel is then the 4 px barrier width. */
  tileSize: 8,
  tileScale: 4,
  road: {
    asphalt: 'road_asphalt_tile',
    edgeLeft: 'road_edge_left_tile',
    edgeRight: 'road_edge_right_tile',
    vergeLeft: 'road_verge_left_tile',
    vergeRight: 'road_verge_right_tile',
    /** Grass rows cycle through these, so the roadside visibly scrolls. */
    grass: ['grass_tile', 'grass_tufts_tile', 'grass_tile', 'grass_tile', 'grass_flowers_tile', 'grass_tile', 'grass_tufts_tile'],
  },
  /** A 16 px tile with grass round it, drawn at 2× to fit the 40 px of grass beside the verge. */
  bush: { frame: 'grass_bush', scale: 2 },
  /** Body 8×12 at 3× is 24×36, centred on the 26×44 hitbox. */
  player: { frame: 'car_red', scale: 3, shadow: 1 },
  /** Turned 45° towards the slide while skidding. */
  playerSkidLeft: { frame: 'car_red_ccw45', scale: 3, shadow: 1 },
  playerSkidRight: { frame: 'car_red_cw45', scale: 3, shadow: 1 },
  traffic: {
    /** Body 6×10 at 4× is exactly the 24×40 hitbox. */
    yellow: { frame: 'car_small_yellow', scale: 4, shadow: 1 },
    /** car_red is the player, so red traffic uses the salmon car. Body 24×36. */
    red: { frame: 'car_salmon', scale: 3, shadow: 1 },
    blue: { frame: 'car_blue', scale: 3, shadow: 1 },
    /** Drawn in code. Body 10×20 at 3× is exactly the 30×60 hitbox. */
    truck: { frame: 'truck', scale: 3, shadow: 1 },
    /** The white car, tinted with the rainbow hue cycle. */
    fuelCar: { frame: 'car_police', scale: 3, shadow: 1 },
    /** Drawn in code. 10×6 at 4× is exactly the 40×24 hitbox. */
    oil: { frame: 'oil_puddle', scale: 4, shadow: 0 },
  },
} as const;
