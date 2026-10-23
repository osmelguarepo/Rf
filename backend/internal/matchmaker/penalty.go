package matchmaker

import (
	"time"

	"fuelrivals/backend/internal/store"
)

// NextPenalty is the state after one more strike (a player who did not confirm a found match, declined it, or left a
// race). Strikes older than PenaltyWindow are forgotten first. The first PenaltyFree strikes of the window only warn;
// each one after that bans the queue for PenaltyBase, then twice as long, and so on up to PenaltyMax.
func NextPenalty(prev store.Penalty, now time.Time, p Params) store.Penalty {
	strikes := prev.Strikes
	if !prev.LastAt.IsZero() && now.Sub(prev.LastAt) > p.PenaltyWindow {
		strikes = 0
	}
	strikes++
	out := store.Penalty{Strikes: strikes, LastAt: now, BannedUntil: prev.BannedUntil}
	if over := strikes - p.PenaltyFree; over > 0 {
		shift := over - 1
		if shift > 20 {
			shift = 20
		}
		d := p.PenaltyBase << shift
		if d > p.PenaltyMax || d <= 0 {
			d = p.PenaltyMax
		}
		out.BannedUntil = now.Add(d)
	}
	return out
}
