// Package names derives the display name of a player from the Steam persona name (SPEC_ONLINE 4): upper case, only the
// characters of scripts/app/names.gd CHARS, filtered against insults, cut to 8; under 3 it becomes "P" plus the last
// digits of the SteamID.
package names

import (
	_ "embed"
	"strings"
	"unicode"
)

const (
	// Chars mirrors Names.CHARS in scripts/app/names.gd.
	Chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	// MinLength and MaxLength mirror Names.MIN_LENGTH and Names.MAX_LENGTH.
	MinLength = 3
	MaxLength = 8
)

// BlocklistVersion is bumped whenever blocklist.txt changes (SPEC_ONLINE 15, row 17: a versioned list).
const BlocklistVersion = 1

//go:embed blocklist.txt
var blocklistRaw string

var blocked = func() []string {
	var out []string
	for _, line := range strings.Split(blocklistRaw, "\n") {
		line = strings.TrimSpace(line)
		if line != "" && !strings.HasPrefix(line, "#") {
			out = append(out, strings.ToUpper(line))
		}
	}
	return out
}()

// Letters that stand in for others when someone tries to dodge the list (0 for O and so on).
var lookalike = strings.NewReplacer("0", "O", "1", "I", "3", "E", "4", "A", "5", "S", "7", "T", "8", "B")

// Clean is the persona name reduced to Chars (letters without accents, digits), upper case, at most MaxLength.
func Clean(persona string) string {
	var b strings.Builder
	for _, r := range strings.ToUpper(persona) {
		if r > unicode.MaxASCII {
			continue
		}
		if strings.ContainsRune(Chars, r) {
			b.WriteRune(r)
		}
	}
	s := b.String()
	if len(s) > MaxLength {
		s = s[:MaxLength]
	}
	return s
}

// Insulting reports whether a name contains an entry of the blocklist, also written with look-alike digits.
func Insulting(name string) bool {
	upper := strings.ToUpper(name)
	plain := lookalike.Replace(upper)
	for _, w := range blocked {
		if strings.Contains(upper, w) || strings.Contains(plain, w) {
			return true
		}
	}
	return false
}

// Fallback is "P" plus the last digits of the SteamID (or of any numeric id).
func Fallback(steamID string) string {
	digits := steamID
	if len(digits) > 4 {
		digits = digits[len(digits)-4:]
	}
	return "P" + digits
}

// Display is the name shown for a persona name. The filter looks at the whole cleaned persona before it is cut, so a
// word that starts beyond the eighth character still counts.
func Display(persona, steamID string) string {
	full := strings.Builder{}
	for _, r := range strings.ToUpper(persona) {
		if r <= unicode.MaxASCII && strings.ContainsRune(Chars, r) {
			full.WriteRune(r)
		}
	}
	if Insulting(full.String()) {
		return Fallback(steamID)
	}
	name := Clean(persona)
	if len(name) < MinLength {
		return Fallback(steamID)
	}
	return name
}
