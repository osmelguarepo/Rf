// Command loadbot registers N fake guests against a running Fuel Rivals API, queues them, confirms the matches that are
// found and fetches the join tickets, then prints a report (docs/MATCHMAKING.md). With -simulate-server it also plays
// the game server: it registers, sends heartbeats and posts a result for every match, so the run reaches settlement.
//
//	loadbot -url http://localhost:8080 -n 60 -ramp 20s
//	loadbot -url http://localhost:8080 -n 60 -simulate-server -register-token $SERVER_REGISTER_TOKEN -admin-token $ADMIN_TOKEN
//
// The API limits guest accounts per IP address (RATE_GUEST_PER_HOUR, 10 by default): raise it on the test instance.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"fuelrivals/backend/internal/loadbot"
)

func main() {
	url := flag.String("url", def(os.Getenv("LOADBOT_URL"), "http://localhost:8080"), "API base URL ($LOADBOT_URL)")
	n := flag.Int("n", 12, "number of fake guests")
	region := flag.String("region", "eu", "region name of the reported latency")
	latency := flag.Int("latency", 40, "reported latency to that region, ms")
	ramp := flag.Duration("ramp", 10*time.Second, "spread the arrivals over this time")
	poll := flag.Duration("poll", time.Second, "status polling interval")
	timeout := flag.Duration("timeout", 3*time.Minute, "give up after this long")
	seed := flag.Int64("seed", 1, "random seed")
	sim := flag.Bool("simulate-server", false, "also play the game server (register, heartbeat, post results)")
	regTok := flag.String("register-token", os.Getenv("SERVER_REGISTER_TOKEN"), "SERVER_REGISTER_TOKEN, for -simulate-server")
	admTok := flag.String("admin-token", os.Getenv("ADMIN_TOKEN"), "ADMIN_TOKEN, for -simulate-server")
	srvName := flag.String("server-name", "loadbot", "name of the simulated game server")
	srvURL := flag.String("server-url", "ws://localhost:9", "websocket URL given to the simulated game server")
	quiet := flag.Bool("quiet", false, "print only the JSON report")
	flag.Parse()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	cfg := loadbot.Config{
		BaseURL: *url, Players: *n, Region: *region, LatencyMS: *latency, Ramp: *ramp, Poll: *poll, Timeout: *timeout, Seed: *seed,
		SimulateServer: *sim, RegisterToken: *regTok, AdminToken: *admTok, ServerName: *srvName, ServerURL: *srvURL,
	}
	if !*quiet {
		cfg.Logf = func(f string, a ...any) { fmt.Fprintf(os.Stderr, f+"\n", a...) }
	}
	rep, err := loadbot.Run(ctx, cfg)
	if err != nil {
		fmt.Fprintln(os.Stderr, "loadbot:", err)
		os.Exit(2)
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	_ = enc.Encode(rep)
	if rep.Failed > 0 {
		os.Exit(1)
	}
}

func def(v, d string) string {
	if v == "" {
		return d
	}
	return v
}
