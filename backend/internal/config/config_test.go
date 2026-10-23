package config

import (
	"strings"
	"testing"
	"time"
)

func env(m map[string]string) func(string) string { return func(k string) string { return m[k] } }

func valid() map[string]string {
	return map[string]string{
		"DATABASE_URL": "postgres://x", "PUBLIC_URL": "https://play.example.com/",
		"MASTER_KEY": strings.Repeat("ab", 32), "BAN_SALT": "0123456789abcdef",
		"ADMIN_TOKEN": strings.Repeat("a", 24), "SERVER_REGISTER_TOKEN": strings.Repeat("b", 24),
	}
}

func TestValidConfigAndDefaults(t *testing.T) {
	c, err := FromLookup(env(valid()))
	if err != nil {
		t.Fatal(err)
	}
	if c.PublicURL != "https://play.example.com" || c.APIPrefix != "/api" || c.SessionTTL != 24*time.Hour ||
		c.GuestTTL != 7*24*time.Hour || c.ExchangeTTL != time.Minute || len(c.MasterKey) != 32 {
		t.Errorf("%+v", c)
	}
}

func TestInvalidValuesAreAllReported(t *testing.T) {
	m := valid()
	m["MASTER_KEY"] = "short"
	m["PUBLIC_URL"] = "http://example.com"
	m["ADMIN_TOKEN"] = "x"
	m["SESSION_TTL"] = "soon"
	m["RATE_LOGIN_PER_MIN"] = "-3"
	_, err := FromLookup(env(m))
	if err == nil {
		t.Fatal("want an error")
	}
	for _, want := range []string{"MASTER_KEY", "PUBLIC_URL", "ADMIN_TOKEN", "SESSION_TTL", "RATE_LOGIN_PER_MIN"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("missing %s in %v", want, err)
		}
	}
}
