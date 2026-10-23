package names

import "testing"

func TestDisplay(t *testing.T) {
	const id = "76561198000001234"
	cases := map[string]string{
		"Speedy":            "SPEEDY",
		"Speedy Gonzales":   "SPEEDYGO",
		"ñandú":             "AND", // accented letters drop
		"é":                 "P1234",
		"##":                "P1234",
		"ab":                "P1234",
		"abc":               "ABC",
		"日本語name":           "NAME",
		"shit_driver":       "P1234",
		"5H1T":              "P1234", // look-alike digits
		"Hello Cunt Friend": "P1234", // the word starts after the cut
		"Passer":            "PASSER",
	}
	for in, want := range cases {
		if got := Display(in, id); got != want {
			t.Errorf("Display(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestDisplayOnlyUsesAllowedCharacters(t *testing.T) {
	got := Display("a-b_c d.e!f?g/h\\i", "76561198000001234")
	for _, r := range got {
		if !containsRune(Chars, r) {
			t.Fatalf("%q has %q", got, r)
		}
	}
	if len(got) > MaxLength || len(got) < MinLength {
		t.Fatalf("length of %q", got)
	}
}

func containsRune(s string, r rune) bool {
	for _, c := range s {
		if c == r {
			return true
		}
	}
	return false
}
