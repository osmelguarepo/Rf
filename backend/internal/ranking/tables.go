// Package ranking ports scripts/sim/ranking.gd exactly (docs/SPEC_RANKING.md) and adds the hidden rating.
//
// The visible ranking is a fixed table by field size; a Go test compares these tables with
// testdata/ranking_tables.json, which tools/export_ranking_tables.gd generates from ranking.gd.
package ranking

// Tables is the change for each place, best first, by number of cars (ranking.gd TABLES).
var Tables = map[int][]int{
	2: {20, -20},
	3: {25, 0, -25},
	4: {30, 10, -10, -30},
	5: {30, 15, 0, -15, -30},
	6: {30, 18, 8, -8, -18, -30},
}

// DivisionStarts is where each division starts, lowest first (ranking.gd DIVISION_STARTS).
var DivisionStarts = []int{0, 300, 700, 1200, 1800}

// DivisionNames are the division names (ranking.gd DIVISION_NAMES).
var DivisionNames = []string{"BRONZE", "SILVER", "GOLD", "PLATINUM", "DIAMOND"}

// RacePoints are the points of a race by finishing place (config.gd RACE_POINTS). Settlement only needs final places,
// but the parity test covers it so the two sides cannot drift.
var RacePoints = []int{10, 7, 5, 3, 2, 1}

// MaxDivisionGap is the largest difference in division number allowed between humans of a ranked match (SPEC_ONLINE 16.3).
const MaxDivisionGap = 2

// Delta is the points gained (or lost, negative) by the car in place (0 for the first) of a field of field cars.
func Delta(field, place int) int {
	table, ok := Tables[field]
	if !ok || place < 0 || place >= len(table) {
		return 0
	}
	return table[place]
}

// Apply is a total after a change: never below 0.
func Apply(points, change int) int {
	if points+change < 0 {
		return 0
	}
	return points + change
}

// Division is the division of a total, 0 for the lowest.
func Division(points int) int {
	found := 0
	for i, start := range DivisionStarts {
		if points >= start {
			found = i
		}
	}
	return found
}

// DivisionName is the name of the division of a total.
func DivisionName(points int) string { return DivisionNames[Division(points)] }

// PointsToNext is the points to the next division, or -1 in the highest.
func PointsToNext(points int) int {
	next := Division(points) + 1
	if next >= len(DivisionStarts) {
		return -1
	}
	return DivisionStarts[next] - points
}
