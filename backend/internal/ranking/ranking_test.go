package ranking

import (
	"encoding/json"
	"math"
	"os"
	"reflect"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

type exportFile struct {
	Tables         map[string][]int `json:"tables"`
	DivisionStarts []int            `json:"division_starts"`
	DivisionNames  []string         `json:"division_names"`
	RacePoints     []int            `json:"race_points"`
	Divisions      []struct {
		Points   int    `json:"points"`
		Division int    `json:"division"`
		Name     string `json:"name"`
		ToNext   int    `json:"to_next"`
	} `json:"divisions"`
	Applies []struct {
		Points int `json:"points"`
		Change int `json:"change"`
		Result int `json:"result"`
	} `json:"applies"`
}

func loadExpected(t *testing.T) exportFile {
	t.Helper()
	raw, err := os.ReadFile("../../testdata/ranking_tables.json")
	if err != nil {
		t.Fatalf("testdata/ranking_tables.json is missing (run tools/export_ranking_tables.gd): %v", err)
	}
	var e exportFile
	if err := json.Unmarshal(raw, &e); err != nil {
		t.Fatal(err)
	}
	return e
}

// The Go tables must equal the file the Godot tool generates from ranking.gd.
func TestParityWithGodotExport(t *testing.T) {
	e := loadExpected(t)
	if len(e.Tables) != len(Tables) {
		t.Fatalf("table count: file %d, Go %d", len(e.Tables), len(Tables))
	}
	for k, row := range e.Tables {
		field, _ := strconv.Atoi(k)
		if !reflect.DeepEqual(row, Tables[field]) {
			t.Errorf("table for %d cars: file %v, Go %v", field, row, Tables[field])
		}
		for place, want := range row {
			if got := Delta(field, place); got != want {
				t.Errorf("Delta(%d,%d) = %d, want %d", field, place, got, want)
			}
		}
	}
	if !reflect.DeepEqual(e.DivisionStarts, DivisionStarts) || !reflect.DeepEqual(e.DivisionNames, DivisionNames) {
		t.Errorf("divisions differ: file %v %v", e.DivisionStarts, e.DivisionNames)
	}
	if !reflect.DeepEqual(e.RacePoints, RacePoints) {
		t.Errorf("race points: file %v, Go %v", e.RacePoints, RacePoints)
	}
	for _, d := range e.Divisions {
		if Division(d.Points) != d.Division || DivisionName(d.Points) != d.Name || PointsToNext(d.Points) != d.ToNext {
			t.Errorf("points %d: Go %d %s %d, file %d %s %d", d.Points, Division(d.Points), DivisionName(d.Points),
				PointsToNext(d.Points), d.Division, d.Name, d.ToNext)
		}
	}
	for _, a := range e.Applies {
		if got := Apply(a.Points, a.Change); got != a.Result {
			t.Errorf("Apply(%d,%d) = %d, want %d", a.Points, a.Change, got, a.Result)
		}
	}
	// Out of range places and unknown sizes give 0, as in ranking.gd.
	if Delta(2, 2) != 0 || Delta(2, -1) != 0 || Delta(7, 0) != 0 || Delta(1, 0) != 0 {
		t.Error("out of range deltas must be 0")
	}
}

var (
	gdTables = regexp.MustCompile(`(?m)^\t(\d): \[([-\d, ]+)\],`)
	gdArray  = func(name string) *regexp.Regexp {
		return regexp.MustCompile(`const ` + name + `[^=]*= \[([^\]]*)\]`)
	}
)

// When the Godot sources are next to the module, the Go tables are also compared with ranking.gd and config.gd directly.
func TestParityWithGodotSource(t *testing.T) {
	gd, err := os.ReadFile("../../../scripts/sim/ranking.gd")
	if err != nil {
		t.Skip("scripts/sim/ranking.gd not found (module built outside the repository)")
	}
	matches := gdTables.FindAllStringSubmatch(string(gd), -1)
	if len(matches) != len(Tables) {
		t.Fatalf("found %d tables in ranking.gd, Go has %d", len(matches), len(Tables))
	}
	for _, m := range matches {
		field, _ := strconv.Atoi(m[1])
		if !reflect.DeepEqual(parseInts(m[2]), Tables[field]) {
			t.Errorf("table %d: ranking.gd %s, Go %v", field, m[2], Tables[field])
		}
	}
	starts := gdArray("DIVISION_STARTS").FindStringSubmatch(string(gd))
	if starts == nil || !reflect.DeepEqual(parseInts(starts[1]), DivisionStarts) {
		t.Errorf("DIVISION_STARTS differ: %v vs %v", starts, DivisionStarts)
	}
	names := gdArray("DIVISION_NAMES").FindStringSubmatch(string(gd))
	if names == nil || strings.ReplaceAll(strings.ReplaceAll(names[1], `"`, ""), " ", "") != strings.Join(DivisionNames, ",") {
		t.Errorf("DIVISION_NAMES differ: %v vs %v", names, DivisionNames)
	}
	cfg, err := os.ReadFile("../../../scripts/sim/config.gd")
	if err != nil {
		t.Skip("config.gd not found")
	}
	rp := gdArray("RACE_POINTS").FindStringSubmatch(string(cfg))
	if rp == nil || !reflect.DeepEqual(parseInts(rp[1]), RacePoints) {
		t.Errorf("RACE_POINTS differ: %v vs %v", rp, RacePoints)
	}
}

func parseInts(s string) []int {
	var out []int
	for _, p := range strings.Split(s, ",") {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		n, err := strconv.Atoi(p)
		if err != nil {
			panic(err)
		}
		out = append(out, n)
	}
	return out
}

func TestTablesAreSymmetricForEvenFields(t *testing.T) {
	for field, row := range Tables {
		sum := 0
		for _, d := range row {
			sum += d
		}
		if field%2 == 0 && sum != 0 {
			t.Errorf("field %d does not sum to 0: %d", field, sum)
		}
		for i := range row {
			if row[i] != -row[len(row)-1-i] {
				t.Errorf("field %d is not symmetric", field)
			}
		}
	}
}

func TestDivisionEdges(t *testing.T) {
	cases := map[int]int{0: 0, 299: 0, 300: 1, 699: 1, 700: 2, 1199: 2, 1200: 3, 1799: 3, 1800: 4, 99999: 4}
	for p, want := range cases {
		if got := Division(p); got != want {
			t.Errorf("Division(%d) = %d, want %d", p, got, want)
		}
	}
	if PointsToNext(1800) != -1 || PointsToNext(299) != 1 {
		t.Error("PointsToNext")
	}
}

func TestEvaluate(t *testing.T) {
	none := func(a, b int64) int { return 0 }
	c := func(points int, ip string) Candidate { return Candidate{Points: points, IPPrefix: ip} }
	cases := []struct {
		name   string
		cands  []Candidate
		recent func(a, b int64) int
		want   string
	}{
		{"one human", []Candidate{c(0, "")}, none, ReasonFewHumans},
		{"two humans", []Candidate{c(0, "a"), c(100, "b")}, none, ReasonOK},
		{"gap of 2 divisions", []Candidate{c(0, "a"), c(700, "b")}, none, ReasonOK},
		{"gap of 3 divisions", []Candidate{c(0, "a"), c(1200, "b")}, none, ReasonDivisionGap},
		{"all within 2 but the ends are not", []Candidate{c(0, "a"), c(300, "b"), c(1200, "c")}, none, ReasonDivisionGap},
		{"same subnet", []Candidate{c(0, "10.0.0"), c(0, "10.0.0")}, none, ReasonSameSubnet},
		{"unknown subnets do not match", []Candidate{c(0, ""), c(0, "")}, none, ReasonOK},
		{"the 3rd meeting today is fine", []Candidate{c(0, "a"), c(0, "b")}, func(a, b int64) int { return 2 }, ReasonOK},
		{"the 4th meeting today", []Candidate{c(0, "a"), c(0, "b")}, func(a, b int64) int { return 3 }, ReasonRepeatPairing},
		{"seven humans", []Candidate{c(0, "1"), c(0, "2"), c(0, "3"), c(0, "4"), c(0, "5"), c(0, "6"), c(0, "7")}, none, ReasonTooManyHumans},
	}
	for _, tc := range cases {
		if got := Evaluate(tc.cands, tc.recent); got.Reason != tc.want || got.Ranked != (tc.want == ReasonOK) {
			t.Errorf("%s: got %+v, want %s", tc.name, got, tc.want)
		}
	}
}

func TestSettleOrdersLeaversLast(t *testing.T) {
	// Four humans: places reported 1..4 (bots took none here), the first one left.
	out := Settle([]Entry{{1, 1, true}, {2, 2, false}, {3, 3, false}, {4, 4, false}})
	want := map[int64]int{2: 30, 3: 10, 4: -10, 1: -30}
	for _, o := range out {
		if o.Delta != want[o.PlayerID] {
			t.Errorf("player %d: delta %d, want %d", o.PlayerID, o.Delta, want[o.PlayerID])
		}
	}
	if out[len(out)-1].PlayerID != 1 || !out[len(out)-1].Abandoned {
		t.Error("the leaver comes last")
	}
}

func TestSettleTwoHumansRemainingWins(t *testing.T) {
	out := Settle([]Entry{{10, 1, true}, {11, 5, false}})
	if out[0].PlayerID != 11 || out[0].Delta != 20 || out[1].PlayerID != 10 || out[1].Delta != -20 {
		t.Errorf("remaining human must win: %+v", out)
	}
}

func TestSettleManyLeaversAllGetLastPlace(t *testing.T) {
	out := Settle([]Entry{{1, 1, true}, {2, 2, true}, {3, 6, false}})
	for _, o := range out {
		switch o.PlayerID {
		case 3:
			if o.Delta != 25 {
				t.Errorf("stayer %d", o.Delta)
			}
		default:
			if o.Delta != -25 {
				t.Errorf("leaver %d got %d", o.PlayerID, o.Delta)
			}
		}
	}
}

// The worked example of the Glicko-2 paper (Glickman 2013, section 4).
func TestGlicko2PaperExample(t *testing.T) {
	player := Skill{Rating: 1500, Dev: 200, Vol: 0.06}
	got := player.Update([]Opponent{
		{Skill{1400, 30, 0.06}, 1},
		{Skill{1550, 100, 0.06}, 0},
		{Skill{1700, 300, 0.06}, 0},
	})
	if math.Abs(got.Rating-1464.06) > 0.05 || math.Abs(got.Dev-151.52) > 0.05 || math.Abs(got.Vol-0.05999) > 0.0001 {
		t.Errorf("got %+v, want about 1464.06 / 151.52 / 0.05999", got)
	}
}

func TestRatePlacementsWinnerGoesUp(t *testing.T) {
	skills := []Skill{NewSkill(), NewSkill(), NewSkill()}
	out := RatePlacements([]int{1, 2, 3}, skills)
	if !(out[0].Rating > out[1].Rating && out[1].Rating > out[2].Rating) {
		t.Errorf("order of ratings: %+v", out)
	}
	if out[0].Dev >= DefaultDev {
		t.Error("deviation must shrink after a match")
	}
	if !NewSkill().Provisional(0) || (Skill{1500, 50, 0.06}).Provisional(10) {
		t.Error("provisional flag")
	}
}
