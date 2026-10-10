import { describe, expect, it } from 'vitest';
import { PLAYER, STAGE } from '../src/config';
import { createRng } from '../src/game/rng';
import { advanceSpawner, createSpawner, laneOf, laneX, nextGap, stepTraffic, type TrafficCar } from '../src/game/traffic';

function makeCar(overrides: Partial<TrafficCar> = {}): TrafficCar {
  return {
    id: 1,
    kind: 'yellow',
    x: laneX(1, 24),
    y: 100,
    w: 24,
    h: 40,
    kmh: 80,
    targetX: null,
    lanesLeft: 0,
    laneTimer: 99,
    passed: false,
    consumed: false,
    struck: false,
    ...overrides,
  };
}

describe('lanes', () => {
  it('laneOf is the inverse of laneX for every lane', () => {
    for (let lane = 0; lane < 3; lane++) {
      expect(laneOf(laneX(lane, 24), 24)).toBe(lane);
    }
  });
});

describe('stepTraffic relative motion', () => {
  it('a car slower than the player drifts down the screen', () => {
    const [moved] = stepTraffic([makeCar({ kmh: 80 })], 180, 167, createRng(1), 1).cars;
    expect(moved.y).toBeGreaterThan(100);
  });

  it('a car faster than the player drifts up and is removed once it leaves the top', () => {
    const result = stepTraffic([makeCar({ kmh: 200, y: -100, h: 40 })], 0, 167, createRng(1), 1);
    expect(result.cars).toHaveLength(0);
  });

  it('oil patches stay still relative to the road only when the player is stopped', () => {
    const oil = makeCar({ kind: 'oil', kmh: 0, y: 300, w: 40, h: 24 });
    const [moved] = stepTraffic([oil], 100, 167, createRng(1), 1).cars;
    expect(moved.y).toBeGreaterThan(300);
  });
});

describe('passing', () => {
  it('awards exactly one pass per car, once it is fully behind the player', () => {
    const playerBottom = PLAYER.y + PLAYER.height;
    const rng = createRng(1);
    const car = makeCar({ y: playerBottom - 1, kmh: 0 });

    const first = stepTraffic([car], 150, 167, rng, 0.1);
    expect(first.passedCount).toBe(1);
    expect(first.cars[0].passed).toBe(true);

    const second = stepTraffic(first.cars, 150, 167, rng, 0.1);
    expect(second.passedCount).toBe(0);
  });

  it('oil and fuel cars are never counted as passed cars', () => {
    const playerBottom = PLAYER.y + PLAYER.height;
    const result = stepTraffic(
      [makeCar({ kind: 'oil', y: playerBottom - 1, kmh: 0 }), makeCar({ kind: 'fuelCar', y: playerBottom - 1, kmh: 0 })],
      150,
      167,
      createRng(1),
      0.1,
    );
    expect(result.passedCount).toBe(0);
  });
});

describe('lane changes', () => {
  it('a red car changes lane exactly once', () => {
    const rng = createRng(3);
    let cars: TrafficCar[] = [makeCar({ kind: 'red', lanesLeft: 1, laneTimer: 0.01, kmh: 100 })];
    const startLane = laneOf(cars[0].x, cars[0].w);
    for (let i = 0; i < 60 * 10; i++) cars = stepTraffic(cars, 100, 167, rng, 1 / 60).cars;
    expect(cars[0].lanesLeft).toBe(0);
    expect(laneOf(cars[0].x, cars[0].w)).not.toBe(startLane);
  });
});

describe('spawner is driven by road distance', () => {
  it('spawns nothing while the road is not scrolling', () => {
    const rng = createRng(9);
    const r = advanceSpawner(createSpawner(1, rng), [], 1, rng, 0);
    expect(r.cars).toHaveLength(0);
  });

  it('spawns roughly one car per 350 px of road covered, independent of speed', () => {
    const rng = createRng(11);
    let spawner = createSpawner(1, rng);
    let cars: TrafficCar[] = [];
    const seen = new Set<number>();
    const dt = 0.1;
    const playerKmh = 100;
    // 2100 px of road in 10 px steps, moving traffic exactly as the game does.
    for (let d = 0; d < 2100; d += playerKmh * dt) {
      const r = advanceSpawner(spawner, cars, 1, rng, playerKmh * dt);
      spawner = r.spawner;
      for (const c of r.cars) if (c.kind !== 'oil' && c.kind !== 'fuelCar') seen.add(c.id);
      cars = stepTraffic(r.cars, playerKmh, 167, rng, dt).cars;
    }
    expect(seen.size).toBeGreaterThanOrEqual(4);
    expect(seen.size).toBeLessThanOrEqual(9);
  });

  it('car gaps never go below the minimum spacing', () => {
    const rng = createRng(3);
    for (let i = 0; i < 200; i++) {
      expect(nextGap('car', 50, rng)).toBeGreaterThanOrEqual(STAGE.minSpawnGap);
    }
  });

  it('later stages have shorter car gaps (busier road)', () => {
    const avg = (stage: number): number => {
      const rng = createRng(5);
      let total = 0;
      for (let i = 0; i < 500; i++) total += nextGap('car', stage, rng);
      return total / 500;
    };
    expect(avg(3)).toBeLessThan(avg(1));
  });
});
