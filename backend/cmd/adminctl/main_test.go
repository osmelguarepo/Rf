package main

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type call struct{ method, path, auth, body string }

func fake(t *testing.T, calls *[]call, answers map[string]string) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		*calls = append(*calls, call{r.Method, r.URL.RequestURI(), r.Header.Get("Authorization"), string(b)})
		if strings.HasSuffix(r.URL.Path, "/replay") {
			w.Header().Set("X-Replay-Format", "gzip")
			_, _ = w.Write([]byte("replaybytes"))
			return
		}
		ans, ok := answers[r.Method+" "+r.URL.Path]
		if !ok {
			w.WriteHeader(404)
			_, _ = w.Write([]byte(`{"error":"not_found","message":"nope"}`))
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(ans))
	}))
}

func exec(t *testing.T, url string, args ...string) (int, string, string) {
	var out, errb bytes.Buffer
	env := func(k string) string {
		if k == "ADMIN_TOKEN" {
			return "tok-0123456789"
		}
		return ""
	}
	code := run(context.Background(), append([]string{"-url", url}, args...), env, &out, &errb)
	return code, out.String(), errb.String()
}

func TestCommands(t *testing.T) {
	var calls []call
	ts := fake(t, &calls, map[string]string{
		"GET /admin/servers":          `{"servers":[{"server_id":"1","name":"eu-1","region":"eu","alive":true,"draining":false,"open_matches":2,"capacity":20,"sim_hash":"abc","url":"wss://eu"}]}`,
		"GET /admin/matches":          `{"matches":[{"match_id":"9","server_id":"1","status":"assigned","ranked":true,"rank_reason":"ranked","humans":3,"bots":3,"created_at":"2026-10-23T12:00:00Z","player_ids":["4","5","6"]}]}`,
		"GET /admin/matches/9":        `{"match_id":"9","status":"assigned"}`,
		"GET /admin/queue":            `{"queue":[{"player_id":"4","points":120,"guest":false,"wait_s":12,"band_divisions":2,"priority":false}],"pending":[{"match_id":"10","server_id":"1","players":["5","6"],"confirmed":["5"],"ready_deadline_unix":1}]}`,
		"POST /admin/matches/9/annul": `{"match_id":"9","status":"void"}`,
		"POST /admin/players/4/ban":   `{"banned":true}`,
		"POST /admin/players/4/unban": `{"banned":false}`,
		"POST /admin/servers/1/drain": `{"drain":true}`,
	})
	defer ts.Close()

	code, out, _ := exec(t, ts.URL, "servers")
	if code != 0 || !strings.Contains(out, "eu-1") || !strings.Contains(out, "2/20") {
		t.Errorf("servers %d %q", code, out)
	}
	code, out, _ = exec(t, ts.URL, "matches", "-status", "assigned", "-limit", "5")
	if code != 0 || !strings.Contains(out, "4,5,6") || calls[len(calls)-1].path != "/admin/matches?status=assigned&limit=5" {
		t.Errorf("matches %d %q %v", code, out, calls[len(calls)-1])
	}
	if code, out, _ = exec(t, ts.URL, "match", "9"); code != 0 || !strings.Contains(out, `"status": "assigned"`) {
		t.Errorf("match %d %q", code, out)
	}
	if code, out, _ = exec(t, ts.URL, "queue"); code != 0 || !strings.Contains(out, "waiting: 1") || !strings.Contains(out, "match 10") {
		t.Errorf("queue %d %q", code, out)
	}
	if code, _, _ = exec(t, ts.URL, "annul", "9", "bad", "server"); code != 0 || calls[len(calls)-1].body != `{"reason":"bad server"}` {
		t.Errorf("annul %d %v", code, calls[len(calls)-1])
	}
	if code, _, _ = exec(t, ts.URL, "ban", "4", "cheating"); code != 0 || calls[len(calls)-1].body != `{"reason":"cheating"}` {
		t.Errorf("ban %d %v", code, calls[len(calls)-1])
	}
	if code, _, _ = exec(t, ts.URL, "unban", "4"); code != 0 {
		t.Error("unban")
	}
	if code, out, _ = exec(t, ts.URL, "drain", "1"); code != 0 || !strings.Contains(out, "draining") || calls[len(calls)-1].body != `{"drain":true}` {
		t.Errorf("drain %d %q %v", code, out, calls[len(calls)-1])
	}
	if code, _, _ = exec(t, ts.URL, "drain", "1", "off"); code != 0 || calls[len(calls)-1].body != `{"drain":false}` {
		t.Errorf("drain off %v", calls[len(calls)-1])
	}
	for _, c := range calls {
		if c.auth != "Bearer tok-0123456789" {
			t.Errorf("auth header %q on %s", c.auth, c.path)
		}
	}
	file := filepath.Join(t.TempDir(), "r.bin")
	if code, out, _ = exec(t, ts.URL, "replay", "-o", file, "9"); code != 0 || !strings.Contains(out, "11 bytes") {
		t.Errorf("replay %d %q", code, out)
	}
	if b, _ := os.ReadFile(file); string(b) != "replaybytes" {
		t.Errorf("replay file %q", b)
	}
}

func TestErrorsAndUsage(t *testing.T) {
	var calls []call
	ts := fake(t, &calls, nil)
	defer ts.Close()
	if code, _, e := exec(t, ts.URL, "match", "1"); code != 1 || !strings.Contains(e, "not_found") {
		t.Errorf("API error: %d %q", code, e)
	}
	if code, _, _ := exec(t, ts.URL); code != 2 {
		t.Error("no command")
	}
	if code, _, _ := exec(t, ts.URL, "frobnicate"); code != 2 {
		t.Error("unknown command")
	}
	if code, _, _ := exec(t, ts.URL, "drain", "1", "maybe"); code != 1 {
		t.Error("bad drain argument")
	}
	var out, errb bytes.Buffer
	if code := run(context.Background(), []string{"servers"}, func(string) string { return "" }, &out, &errb); code != 2 || !strings.Contains(errb.String(), "token") {
		t.Errorf("no token: %d %q", code, errb.String())
	}
}
