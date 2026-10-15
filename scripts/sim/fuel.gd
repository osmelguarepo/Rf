extends RefCounted
## Fuel rules, as src/game/fuel.ts. The tank is a float per car (Car.fuel), from 0 to Config.FUEL_MAX.

const Config := preload("res://scripts/sim/config.gd")
const Rng := preload("res://scripts/sim/rng.gd")


## One step of driving: fuel drains while the run is active, moving or not. Never below 0.
static func drain(amount: float) -> float:
	return maxf(0.0, amount - Config.FUEL_DRAIN_PER_SEC * Config.DT)


## Fuel-car pickup: +10, capped at the tank size. The 1000 points are Config.FUEL_CAR_POINTS.
static func collect(amount: float) -> float:
	return minf(Config.FUEL_MAX, amount + Config.FUEL_PICKUP)


## Roadside crash cost: a whole number of units, CRASH_FUEL_MIN to CRASH_FUEL_MAX inclusive. One RNG draw.
static func crash_cost(rng: Rng) -> int:
	return rng.int_range(Config.CRASH_FUEL_MIN, Config.CRASH_FUEL_MAX)


static func apply_crash(amount: float, rng: Rng) -> float:
	return maxf(0.0, amount - float(crash_cost(rng)))


static func is_empty(amount: float) -> bool:
	return amount <= 0.0


## Stage-clear bonus: 30 points per whole unit left.
static func stage_clear_bonus(amount: float) -> int:
	return floori(amount) * Config.STAGE_CLEAR_POINTS_PER_FUEL
