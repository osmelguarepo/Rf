package ranking

import "sort"

// Reasons a match does not rank.
const (
	ReasonOK            = "ranked"
	ReasonFewHumans     = "fewer_than_2_ranked_humans"
	ReasonTooManyHumans = "more_than_6_humans"
	ReasonDivisionGap   = "division_gap"
	ReasonSameSubnet    = "same_subnet"
	ReasonRepeatPairing = "repeat_pairing"
)

// MaxRepeatPairings is how many times a pair of accounts may be matched in a day before the match stops ranking.
const MaxRepeatPairings = 3

// Candidate is a human seat at assignment time. Guests are not candidates: they never score and are left out by the
// caller (the remaining humans still rank among themselves).
type Candidate struct {
	PlayerID int64
	Points   int
	// IPPrefix is the /24 (IPv4) or /48 (IPv6) of the player's address, "" when unknown. It is kept in memory by the
	// matchmaker and never stored.
	IPPrefix string
}

// Verdict says whether a match ranks, and why not.
type Verdict struct {
	Ranked bool
	Reason string
}

// Evaluate applies the rule of SPEC_ONLINE 16.3: a match ranks only if it has at least 2 ranked humans, all within 2
// divisions of each other (by division number), no two from the same /24, and no pair matched more than
// MaxRepeatPairings times today. recent(a, b) is how many times the pair played together earlier today: the 4th meeting of the day does not rank.
func Evaluate(c []Candidate, recent func(a, b int64) int) Verdict {
	if len(c) < 2 {
		return Verdict{false, ReasonFewHumans}
	}
	if len(c) > 6 {
		return Verdict{false, ReasonTooManyHumans}
	}
	lo, hi := Division(c[0].Points), Division(c[0].Points)
	for _, x := range c {
		d := Division(x.Points)
		if d < lo {
			lo = d
		}
		if d > hi {
			hi = d
		}
	}
	if hi-lo > MaxDivisionGap {
		return Verdict{false, ReasonDivisionGap}
	}
	for i := range c {
		for j := i + 1; j < len(c); j++ {
			if c[i].IPPrefix != "" && c[i].IPPrefix == c[j].IPPrefix {
				return Verdict{false, ReasonSameSubnet}
			}
			if recent != nil && recent(c[i].PlayerID, c[j].PlayerID)+1 > MaxRepeatPairings {
				return Verdict{false, ReasonRepeatPairing}
			}
		}
	}
	return Verdict{true, ReasonOK}
}

// Entry is what a game server reports for one ranked human: its place among all cars (1 = first) and whether it left.
type Entry struct {
	PlayerID  int64
	Place     int
	Abandoned bool
}

// Outcome is what the API computes for one human of a ranked match.
type Outcome struct {
	PlayerID   int64
	FinalPlace int // 1-based among the ranked humans; every leaver shares the last place
	Delta      int // table change before the floor of 0
	Abandoned  bool
}

// Settle ranks the humans among themselves (SPEC_ONLINE 16.4: only humans among humans), leavers last, and reads each
// one's change off the table for the number of humans. Those who stayed keep the order of their reported places; the
// ones who left all get the last-place change, whatever their reported place. The remaining human of a 2-human match
// therefore wins the result. The caller applies the floor of 0 (Apply) and stores the change actually applied.
func Settle(entries []Entry) []Outcome {
	field := len(entries)
	stayed := make([]Entry, 0, field)
	left := make([]Entry, 0)
	for _, e := range entries {
		if e.Abandoned {
			left = append(left, e)
		} else {
			stayed = append(stayed, e)
		}
	}
	sort.SliceStable(stayed, func(i, j int) bool { return stayed[i].Place < stayed[j].Place })
	out := make([]Outcome, 0, field)
	for i, e := range stayed {
		out = append(out, Outcome{PlayerID: e.PlayerID, FinalPlace: i + 1, Delta: Delta(field, i)})
	}
	sort.SliceStable(left, func(i, j int) bool { return left[i].PlayerID < left[j].PlayerID })
	for _, e := range left {
		out = append(out, Outcome{PlayerID: e.PlayerID, FinalPlace: len(stayed) + 1, Delta: Delta(field, field-1), Abandoned: true})
	}
	return out
}
