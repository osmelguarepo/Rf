// Command api is the Fuel Rivals account, ranking and match-settlement service (docs/SPEC_ONLINE.md, milestone M3).
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"fuelrivals/backend/internal/api"
	"fuelrivals/backend/internal/config"
	"fuelrivals/backend/internal/steam"
	"fuelrivals/backend/internal/store"
)

func main() {
	// `api healthcheck` is for the container's HEALTHCHECK (the image has no curl): exit 0 if /healthz answers.
	if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
		os.Exit(healthcheck())
	}
	cfg, err := config.FromEnv()
	if err != nil {
		slog.New(slog.NewJSONHandler(os.Stderr, nil)).Error("invalid configuration", "err", err.Error())
		os.Exit(2)
	}
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: level(cfg.LogLevel)}))
	slog.SetDefault(log)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	st, err := connect(ctx, cfg, log)
	if err != nil {
		log.Error("database", "err", err.Error())
		os.Exit(1)
	}
	defer st.Close()
	if err := st.Migrate(ctx); err != nil {
		log.Error("migrations", "err", err.Error())
		os.Exit(1)
	}
	if err := st.EnsureReplayPartitions(ctx, 3); err != nil {
		log.Warn("replay partitions", "err", err.Error())
	}

	var verifier steam.Verifier = steam.Unavailable{}
	fakeSteam := os.Getenv("DEV_FAKE_STEAM") == "1" && (strings.HasPrefix(cfg.PublicURL, "http://localhost") || strings.HasPrefix(cfg.PublicURL, "http://127.0.0.1"))
	if fakeSteam {
		// Local development and tests of the whole stack only: a ticket "ok-<steamid>" logs in as that SteamID.
		verifier = steam.FakeVerifier{}
		log.Warn("DEV_FAKE_STEAM=1: Steam tickets \"ok-<steamid>\" are accepted; never in production")
	} else if cfg.SteamPartnerKey != "" {
		verifier = &steam.TicketVerifier{Key: cfg.SteamPartnerKey, AppID: cfg.SteamAppID, Identity: cfg.SteamTicketIdentity}
	} else {
		log.Warn("STEAM_PARTNER_API_KEY is not set: POST /auth/steam will answer 503")
	}
	var persona steam.Persona = steam.Unavailable{}
	if fakeSteam {
		persona = &steam.FakePersona{}
	} else if cfg.SteamWebAPIKey != "" {
		persona = &steam.PersonaFetcher{Key: cfg.SteamWebAPIKey}
	} else {
		log.Warn("STEAM_WEB_API_KEY is not set: display names fall back to P + the last digits of the SteamID")
	}

	srv := api.New(api.Deps{Config: cfg, Store: st, Verifier: verifier, Persona: persona, SteamHTTP: steam.NewHTTPClient(), Log: log})
	httpSrv := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    16 << 10,
	}

	go background(ctx, st, cfg, log)
	go srv.RunMatchmaker(ctx)

	errc := make(chan error, 1)
	go func() {
		log.Info("listening", "addr", cfg.ListenAddr, "public_url", cfg.PublicURL)
		errc <- httpSrv.ListenAndServe()
	}()
	select {
	case err := <-errc:
		if !errors.Is(err, http.ErrServerClosed) {
			log.Error("server", "err", err.Error())
			os.Exit(1)
		}
	case <-ctx.Done():
		log.Info("shutting down")
		shutdown, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		if err := httpSrv.Shutdown(shutdown); err != nil {
			log.Error("shutdown", "err", err.Error())
			os.Exit(1)
		}
		log.Info("stopped")
	}
}

func healthcheck() int {
	addr := os.Getenv("LISTEN_ADDR")
	if addr == "" {
		addr = ":8080"
	}
	if strings.HasPrefix(addr, ":") {
		addr = "127.0.0.1" + addr
	}
	client := http.Client{Timeout: 3 * time.Second}
	res, err := client.Get("http://" + addr + "/healthz")
	if err != nil {
		return 1
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return 1
	}
	return 0
}

// connect waits for the database for up to a minute (the container may start before PostgreSQL is ready).
func connect(ctx context.Context, cfg config.Config, log *slog.Logger) (*store.Store, error) {
	var lastErr error
	for i := 0; i < 30; i++ {
		st, err := store.Open(ctx, cfg.DatabaseURL, store.Config{MasterKey: cfg.MasterKey, BanSalt: cfg.BanSalt})
		if err == nil {
			return st, nil
		}
		lastErr = err
		log.Warn("waiting for the database", "attempt", i+1)
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(2 * time.Second):
		}
	}
	return nil, lastErr
}

// background runs the periodic jobs: lease expiry, cleanup of expired rows and the monthly replay partitions.
func background(ctx context.Context, st *store.Store, cfg config.Config, log *slog.Logger) {
	leases := time.NewTicker(15 * time.Second)
	cleanup := time.NewTicker(10 * time.Minute)
	partitions := time.NewTicker(24 * time.Hour)
	defer leases.Stop()
	defer cleanup.Stop()
	defer partitions.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-leases.C:
			if res, err := st.ExpireLeases(ctx, cfg.VoidAfter); err != nil {
				log.Error("expire leases", "err", err.Error())
			} else if res.Released > 0 || res.Voided > 0 {
				log.Warn("silent game servers", "released_matches", res.Released, "voided_matches", res.Voided)
			}
		case <-cleanup.C:
			if err := st.Cleanup(ctx); err != nil {
				log.Error("cleanup", "err", err.Error())
			}
		case <-partitions.C:
			if err := st.EnsureReplayPartitions(ctx, 3); err != nil {
				log.Warn("replay partitions", "err", err.Error())
			}
		}
	}
}

func level(s string) slog.Level {
	var l slog.Level
	if err := l.UnmarshalText([]byte(s)); err != nil {
		return slog.LevelInfo
	}
	return l
}
