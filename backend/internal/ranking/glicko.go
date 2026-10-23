package ranking

import "math"

// Hidden rating: Glicko-2 (Glickman, 2013), chosen over OpenSkill because it keeps an explicit rating deviation, which
// gives the "provisional" period for free (a high deviation) and has a closed form we can test with the paper's example.
// A race is treated as a set of pairwise games: each human against each other human, won, drawn or lost by place.
// The hidden rating never changes the visible points; it feeds the matchmaker (strength) and the provisional flag.

const (
	glickoScale = 173.7178
	glickoTau   = 0.5
	glickoEps   = 1e-6

	DefaultRating = 1500.0
	DefaultDev    = 350.0
	DefaultVol    = 0.06

	// ProvisionalDev: above this deviation an account is provisional.
	ProvisionalDev = 110.0
	// ProvisionalGames: fewer ranked matches than this is provisional too.
	ProvisionalGames = 10
)

// Skill is a hidden rating.
type Skill struct {
	Rating float64 // Glicko-2 rating on the 1500 scale
	Dev    float64 // rating deviation
	Vol    float64 // volatility
}

// NewSkill is the starting rating of an account.
func NewSkill() Skill { return Skill{Rating: DefaultRating, Dev: DefaultDev, Vol: DefaultVol} }

// Provisional reports whether the rating is still settling.
func (s Skill) Provisional(rankedMatches int) bool {
	return rankedMatches < ProvisionalGames || s.Dev > ProvisionalDev
}

// Opponent is one game result against another skill: score 1 win, 0.5 draw, 0 loss.
type Opponent struct {
	Skill Skill
	Score float64
}

func g(phi float64) float64 { return 1 / math.Sqrt(1+3*phi*phi/(math.Pi*math.Pi)) }

func expected(mu, muJ, phiJ float64) float64 { return 1 / (1 + math.Exp(-g(phiJ)*(mu-muJ))) }

// Update runs one Glicko-2 rating period with the given games. With no games only the deviation grows.
func (s Skill) Update(games []Opponent) Skill {
	mu := (s.Rating - DefaultRating) / glickoScale
	phi := s.Dev / glickoScale
	sigma := s.Vol
	if len(games) == 0 {
		phi = math.Sqrt(phi*phi + sigma*sigma)
		return Skill{Rating: s.Rating, Dev: math.Min(phi*glickoScale, DefaultDev), Vol: sigma}
	}
	var vInv, deltaSum float64
	for _, o := range games {
		muJ := (o.Skill.Rating - DefaultRating) / glickoScale
		phiJ := o.Skill.Dev / glickoScale
		ej := expected(mu, muJ, phiJ)
		gj := g(phiJ)
		vInv += gj * gj * ej * (1 - ej)
		deltaSum += gj * (o.Score - ej)
	}
	v := 1 / vInv
	delta := v * deltaSum

	a := math.Log(sigma * sigma)
	f := func(x float64) float64 {
		ex := math.Exp(x)
		num := ex * (delta*delta - phi*phi - v - ex)
		den := 2 * math.Pow(phi*phi+v+ex, 2)
		return num/den - (x-a)/(glickoTau*glickoTau)
	}
	A := a
	var B float64
	if delta*delta > phi*phi+v {
		B = math.Log(delta*delta - phi*phi - v)
	} else {
		k := 1.0
		for f(a-k*glickoTau) < 0 {
			k++
		}
		B = a - k*glickoTau
	}
	fA, fB := f(A), f(B)
	for math.Abs(B-A) > glickoEps {
		C := A + (A-B)*fA/(fB-fA)
		fC := f(C)
		if fC*fB <= 0 {
			A, fA = B, fB
		} else {
			fA /= 2
		}
		B, fB = C, fC
	}
	newSigma := math.Exp(A / 2)
	phiStar := math.Sqrt(phi*phi + newSigma*newSigma)
	newPhi := 1 / math.Sqrt(1/(phiStar*phiStar)+1/v)
	newMu := mu + newPhi*newPhi*deltaSum
	return Skill{Rating: newMu*glickoScale + DefaultRating, Dev: newPhi * glickoScale, Vol: newSigma}
}

// RatePlacements gives each human's new hidden rating from the places of a ranked match (lower is better). Every pair
// is a game; humans with the same place draw.
func RatePlacements(places []int, skills []Skill) []Skill {
	out := make([]Skill, len(skills))
	for i := range skills {
		var games []Opponent
		for j := range skills {
			if i == j {
				continue
			}
			score := 0.5
			if places[i] < places[j] {
				score = 1
			} else if places[i] > places[j] {
				score = 0
			}
			games = append(games, Opponent{Skill: skills[j], Score: score})
		}
		out[i] = skills[i].Update(games)
	}
	return out
}
