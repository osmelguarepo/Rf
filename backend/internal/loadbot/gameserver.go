package loadbot

import (
	"context"
	"fmt"
	"sync"
	"time"
)

// gameServer plays the part of a Godot game server: it registers, sends heartbeats and, some seconds after a match is
// assigned to it, posts a result (humans in id order take places 1, 2, ...).
type gameServer struct {
	r       *runner
	id, key string

	mu        sync.Mutex
	firstSeen map[string]time.Time
	settled   map[string]bool
}

func (g *gameServer) hdr() map[string]string {
	return map[string]string{"X-Server-Id": g.id}
}

func (r *runner) startServer(ctx context.Context) (*gameServer, error) {
	if r.cfg.RegisterToken == "" || r.cfg.AdminToken == "" {
		return nil, fmt.Errorf("loadbot: the simulated game server needs the register token and the admin token")
	}
	name := r.cfg.ServerName
	if name == "" {
		name = "loadbot"
	}
	url := r.cfg.ServerURL
	if url == "" {
		url = "ws://localhost:9"
	}
	res, err := r.do(ctx, "POST", "/servers/register", r.cfg.RegisterToken, nil,
		map[string]any{"name": name, "region": r.cfg.Region, "url": url, "capacity": max(r.cfg.Players, 10)})
	if err != nil {
		return nil, err
	}
	if !res.OK() {
		return nil, fmt.Errorf("register server: %w", res.Err())
	}
	var reg struct {
		ServerID string `json:"server_id"`
		Key      string `json:"key"`
	}
	if err := res.JSON(&reg); err != nil || reg.ServerID == "" {
		return nil, fmt.Errorf("register server: bad answer")
	}
	g := &gameServer{r: r, id: reg.ServerID, key: reg.Key, firstSeen: map[string]time.Time{}, settled: map[string]bool{}}
	if err := g.heartbeat(ctx); err != nil {
		return nil, err
	}
	r.logf("simulated game server %s registered", g.id)
	go func() {
		beat := time.NewTicker(5 * time.Second)
		pass := time.NewTicker(500 * time.Millisecond)
		defer beat.Stop()
		defer pass.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-beat.C:
				_ = g.heartbeat(ctx)
			case <-pass.C:
				g.pass(ctx)
			}
		}
	}()
	return g, nil
}

func (g *gameServer) heartbeat(ctx context.Context) error {
	res, err := g.r.do(ctx, "POST", "/servers/heartbeat", g.key, g.hdr(), map[string]any{"capacity": max(g.r.cfg.Players, 10)})
	if err != nil {
		return err
	}
	if !res.OK() {
		return fmt.Errorf("heartbeat: %w", res.Err())
	}
	return nil
}

// pass settles the matches of this server that have been open for a couple of seconds.
func (g *gameServer) pass(ctx context.Context) {
	res, err := g.r.do(ctx, "GET", "/admin/matches?status=assigned&limit=500", g.r.cfg.AdminToken, nil, nil)
	if err != nil || !res.OK() {
		return
	}
	var list struct {
		Matches []struct {
			MatchID   string   `json:"match_id"`
			ServerID  string   `json:"server_id"`
			PlayerIDs []string `json:"player_ids"`
		} `json:"matches"`
	}
	if res.JSON(&list) != nil {
		return
	}
	now := time.Now()
	for _, m := range list.Matches {
		if m.ServerID != g.id {
			continue
		}
		g.mu.Lock()
		if g.settled[m.MatchID] {
			g.mu.Unlock()
			continue
		}
		first, ok := g.firstSeen[m.MatchID]
		if !ok {
			g.firstSeen[m.MatchID] = now
			first = now
		}
		g.mu.Unlock()
		if now.Sub(first) < 1500*time.Millisecond {
			continue
		}
		players := make([]map[string]any, len(m.PlayerIDs))
		for i, id := range m.PlayerIDs {
			players[i] = map[string]any{"player_id": id, "place": i + 1}
		}
		pr, err := g.r.do(ctx, "POST", "/matches/"+m.MatchID+"/result", g.key, g.hdr(), map[string]any{"players": players})
		if err == nil && pr.OK() {
			g.mu.Lock()
			g.settled[m.MatchID] = true
			g.mu.Unlock()
		}
	}
}

// drain keeps settling until `expect` matches are settled or ctx ends.
func (g *gameServer) drain(ctx context.Context, expect int) {
	for g.settledCount() < expect {
		select {
		case <-ctx.Done():
			return
		case <-time.After(300 * time.Millisecond):
		}
		g.pass(ctx)
	}
}

func (g *gameServer) settledCount() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return len(g.settled)
}
