extends RefCounted
## The ranking (docs/SPEC_RANKING.md): the points a person gains or loses at the end of a race match by their final
## place among all the cars, and the divisions the total falls in. Pure: no state, no Godot nodes.
##
## - Points. A fixed table for each field size (2 to 6 cars, bots included), the same shape for every size: the top
##   half gains, the bottom half loses, and the middle car of an odd field stays level.
## - Total. It never goes below 0.
## - Divisions. Fixed thresholds: the division is where the total falls.

## The change for each place, best first, by number of cars.
const TABLES := {
	2: [20, -20],
	3: [25, 0, -25],
	4: [30, 10, -10, -30],
	5: [30, 15, 0, -15, -30],
	6: [30, 18, 8, -8, -18, -30],
}

## Where each division starts, lowest first, and their names.
const DIVISION_STARTS: Array[int] = [0, 300, 700, 1200, 1800]
const DIVISION_NAMES: Array[String] = ["BRONZE", "SILVER", "GOLD", "PLATINUM", "DIAMOND"]


## Points gained (or lost, negative) by the car in `place` (0 for the first) of a field of `field` cars.
static func delta(field: int, place: int) -> int:
	var table: Array = TABLES.get(field, [])
	if place < 0 or place >= table.size():
		return 0
	return table[place]


## A total after a change: never below 0.
static func apply(points: int, change: int) -> int:
	return maxi(0, points + change)


## The division of a total, 0 for the lowest.
static func division(points: int) -> int:
	var found := 0
	for i in DIVISION_STARTS.size():
		if points >= DIVISION_STARTS[i]:
			found = i
	return found


static func division_name(points: int) -> String:
	return DIVISION_NAMES[division(points)]


## Points to the next division, or -1 in the highest.
static func points_to_next(points: int) -> int:
	var next := division(points) + 1
	return -1 if next >= DIVISION_STARTS.size() else DIVISION_STARTS[next] - points
