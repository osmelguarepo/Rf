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

func TestMatchmakingDefaultsAndOverrides(t *testing.T) {
	c, err := FromLookup(env(valid()))
	if err != nil {
		t.Fatal(err)
	}
	if c.QueueMaxWait != 30*time.Second || c.QueueSoloWait != 30*time.Second || c.ReadySeconds != 15*time.Second ||
		c.QueueBandStep != 10*time.Second || c.MaxPingMS != 250 || c.QueueRatePerMin != 20 || c.StatusRatePerMin != 90 ||
		c.PenaltyFree != 2 || c.PenaltyBase != 5*time.Minute || c.PenaltyMax != 2*time.Hour || c.MetricsToken != "" {
		t.Errorf("%+v", c)
	}
	m := valid()
	m["READY_SECONDS"] = "20" // plain seconds
	m["QUEUE_MAX_WAIT"] = "45s"
	m["QUEUE_SOLO_WAIT"] = "1m"
	m["MAX_PING_MS"] = "180"
	m["METRICS_TOKEN"] = strings.Repeat("m", 16)
	c, err = FromLookup(env(m))
	if err != nil {
		t.Fatal(err)
	}
	if c.ReadySeconds != 20*time.Second || c.QueueMaxWait != 45*time.Second || c.QueueSoloWait != time.Minute || c.MaxPingMS != 180 || c.MetricsToken == "" {
		t.Errorf("%+v", c)
	}
	m["METRICS_TOKEN"] = "short"
	m["READY_SECONDS"] = "soon"
	if _, err = FromLookup(env(m)); err == nil || !strings.Contains(err.Error(), "METRICS_TOKEN") || !strings.Contains(err.Error(), "READY_SECONDS") {
		t.Errorf("%v", err)
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
