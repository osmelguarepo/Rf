package api_test

import (
	"context"
	"encoding/hex"
	"net/http/httptest"
	"testing"
	"time"

	"fuelrivals/backend/internal/api"
	"fuelrivals/backend/internal/config"
	"fuelrivals/backend/internal/loadbot"
	"fuelrivals/backend/internal/steam"
	"fuelrivals/backend/internal/testdb"
)

// The load bot against a real (httptest) API with the matching loop running on the real clock and short timers.
func TestLoadBotCompletesAgainstTheAPI(t *testing.T) {
	st := testdb.New(t)
	m := map[string]string{
		"DATABASE_URL": "postgres://unused", "PUBLIC_URL": publicURL,
		"MASTER_KEY": hex.EncodeToString(testdb.MasterKey), "BAN_SALT": string(testdb.BanSalt),
		"ADMIN_TOKEN": adminToken, "SERVER_REGISTER_TOKEN": registerToken,
		"RATE_LOGIN_PER_MIN": "100000", "RATE_GUEST_PER_HOUR": "100000", "RATE_ACCOUNT_PER_MIN": "100000",
		"RATE_QUEUE_PER_MIN": "100000", "RATE_STATUS_PER_MIN": "100000",
		"QUEUE_MAX_WAIT": "2s", "QUEUE_SOLO_WAIT": "2s", "QUEUE_BAND_STEP": "1s", "READY_SECONDS": "5", "MATCHMAKER_TICK": "100ms",
	}
	cfg, err := config.FromLookup(func(k string) string { return m[k] })
	if err != nil {
		t.Fatal(err)
	}
	srv := api.New(api.Deps{Config: cfg, Store: st, Verifier: steam.FakeVerifier{}, Persona: &steam.FakePersona{Names: map[string]string{}}})
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go srv.RunMatchmaker(ctx)

	const n = 20
	rep, err := loadbot.Run(ctx, loadbot.Config{
		BaseURL: ts.URL, Players: n, Ramp: 2 * time.Second, Poll: 100 * time.Millisecond, Timeout: 40 * time.Second, Seed: 7,
		SimulateServer: true, RegisterToken: registerToken, AdminToken: adminToken,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("report: %+v", rep)
	if rep.Failed != 0 || rep.Joined != n {
		t.Fatalf("not everybody joined: %+v", rep)
	}
	total := 0
	for size, count := range rep.GroupSizes {
		if size < 1 || size > 6 {
			t.Errorf("group of %d", size)
		}
		total += size * count
	}
	if total != n {
		t.Errorf("players in groups: %d", total)
	}
	if rep.Matches < 3 || rep.Settled != rep.Matches {
		t.Errorf("matches %d settled %d", rep.Matches, rep.Settled)
	}
	if rep.WaitToJoinP95 > 20 {
		t.Errorf("waits too long: %+v", rep)
	}
	if got := srv.Metrics().Counter("fr_funnel_total", "stage", "finished"); got != n {
		t.Errorf("finished in the funnel: %v", got)
	}
}
