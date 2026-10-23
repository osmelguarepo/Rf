// Command adminctl is the operator's command-line tool for the Fuel Rivals API (docs/MATCHMAKING.md).
//
//	adminctl [-url URL] [-token TOKEN] <command> [arguments]
//
// URL defaults to $ADMIN_URL (or http://localhost:8080), TOKEN to $ADMIN_TOKEN. URL includes the proxy prefix when
// there is one (https://play.example.com/api). Commands:
//
//	servers                       registered game servers, lease, capacity, drain state
//	matches [-status S] [-limit N]  recent matches (S: assigned, settled, void, annulled)
//	match ID                      one match with its players and result
//	queue                         who is waiting and the matches waiting for confirmations
//	annul ID REASON...            void an open match or revert a settled one exactly
//	ban PLAYER_ID [REASON...]     ban an account
//	unban PLAYER_ID               lift a ban and the queue penalty
//	drain SERVER_ID [off]         stop assigning matches to a server (its heartbeat tells it to drain); "off" lifts it
//	replay [-o FILE] ID           download a replay (default replay-ID.bin)
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"text/tabwriter"
	"time"

	"fuelrivals/backend/internal/apiclient"
)

func main() {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	os.Exit(run(ctx, os.Args[1:], os.Getenv, os.Stdout, os.Stderr))
}

type tool struct {
	c     *apiclient.Client
	token string
	out   io.Writer
	err   io.Writer
}

func run(ctx context.Context, args []string, getenv func(string) string, out, errw io.Writer) int {
	fs := flag.NewFlagSet("adminctl", flag.ContinueOnError)
	fs.SetOutput(errw)
	url := fs.String("url", def(getenv("ADMIN_URL"), "http://localhost:8080"), "API base URL ($ADMIN_URL)")
	token := fs.String("token", getenv("ADMIN_TOKEN"), "admin token ($ADMIN_TOKEN)")
	fs.Usage = func() {
		fmt.Fprintln(errw, "usage: adminctl [-url URL] [-token TOKEN] servers|matches|match|queue|annul|ban|unban|drain|replay [arguments]")
	}
	if err := fs.Parse(args); err != nil {
		return 2
	}
	rest := fs.Args()
	if len(rest) == 0 {
		fs.Usage()
		return 2
	}
	if *token == "" {
		fmt.Fprintln(errw, "adminctl: no admin token (-token or $ADMIN_TOKEN)")
		return 2
	}
	t := &tool{c: apiclient.New(*url), token: *token, out: out, err: errw}
	var err error
	switch cmd, a := rest[0], rest[1:]; cmd {
	case "servers":
		err = t.servers(ctx)
	case "matches":
		err = t.matches(ctx, a)
	case "match":
		err = t.one(ctx, a, "/admin/matches/")
	case "queue":
		err = t.queue(ctx)
	case "annul":
		err = t.annul(ctx, a)
	case "ban":
		err = t.ban(ctx, a)
	case "unban":
		err = t.unban(ctx, a)
	case "drain":
		err = t.drain(ctx, a)
	case "replay":
		err = t.replay(ctx, a)
	default:
		fmt.Fprintf(errw, "adminctl: unknown command %q\n", cmd)
		fs.Usage()
		return 2
	}
	if err != nil {
		fmt.Fprintf(errw, "adminctl: %v\n", err)
		return 1
	}
	return 0
}

func def(v, d string) string {
	if v == "" {
		return d
	}
	return v
}

// call sends a request with the admin token and decodes a JSON answer into v (nil: ignored).
func (t *tool) call(ctx context.Context, method, path string, body, v any) error {
	r, err := t.c.Do(ctx, method, path, t.token, nil, body)
	if err != nil {
		return err
	}
	if !r.OK() {
		return r.Err()
	}
	if v != nil {
		return r.JSON(v)
	}
	return nil
}

func (t *tool) printJSON(v any) error {
	enc := json.NewEncoder(t.out)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}

func (t *tool) servers(ctx context.Context) error {
	var res struct {
		Servers []map[string]any `json:"servers"`
	}
	if err := t.call(ctx, "GET", "/admin/servers", nil, &res); err != nil {
		return err
	}
	w := tabwriter.NewWriter(t.out, 0, 4, 2, ' ', 0)
	fmt.Fprintln(w, "ID\tNAME\tREGION\tALIVE\tDRAIN\tOPEN/CAP\tSIM\tURL")
	for _, s := range res.Servers {
		fmt.Fprintf(w, "%v\t%v\t%v\t%v\t%v\t%v/%v\t%v\t%v\n", s["server_id"], s["name"], s["region"], s["alive"], s["draining"],
			s["open_matches"], s["capacity"], s["sim_hash"], s["url"])
	}
	return w.Flush()
}

func (t *tool) matches(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("matches", flag.ContinueOnError)
	fs.SetOutput(t.err)
	status := fs.String("status", "", "assigned, settled, void or annulled")
	limit := fs.Int("limit", 30, "how many")
	if err := fs.Parse(args); err != nil {
		return err
	}
	var res struct {
		Matches []map[string]any `json:"matches"`
	}
	if err := t.call(ctx, "GET", fmt.Sprintf("/admin/matches?status=%s&limit=%d", *status, *limit), nil, &res); err != nil {
		return err
	}
	w := tabwriter.NewWriter(t.out, 0, 4, 2, ' ', 0)
	fmt.Fprintln(w, "MATCH\tSERVER\tSTATUS\tRANKED\tHUMANS\tBOTS\tCREATED\tPLAYERS")
	for _, m := range res.Matches {
		ids := []string{}
		if l, ok := m["player_ids"].([]any); ok {
			for _, x := range l {
				ids = append(ids, fmt.Sprint(x))
			}
		}
		fmt.Fprintf(w, "%v\t%v\t%v\t%v (%v)\t%v\t%v\t%v\t%s\n", m["match_id"], m["server_id"], m["status"], m["ranked"], m["rank_reason"],
			m["humans"], m["bots"], m["created_at"], strings.Join(ids, ","))
	}
	return w.Flush()
}

func (t *tool) one(ctx context.Context, args []string, prefix string) error {
	if len(args) != 1 {
		return fmt.Errorf("usage: match ID")
	}
	var v any
	if err := t.call(ctx, "GET", prefix+args[0], nil, &v); err != nil {
		return err
	}
	return t.printJSON(v)
}

func (t *tool) queue(ctx context.Context) error {
	var v struct {
		Queue   []map[string]any `json:"queue"`
		Pending []map[string]any `json:"pending"`
	}
	if err := t.call(ctx, "GET", "/admin/queue", nil, &v); err != nil {
		return err
	}
	fmt.Fprintf(t.out, "waiting: %d, found and waiting for confirmation: %d\n", len(v.Queue), len(v.Pending))
	w := tabwriter.NewWriter(t.out, 0, 4, 2, ' ', 0)
	fmt.Fprintln(w, "PLAYER\tPOINTS\tGUEST\tWAIT_S\tBAND\tPRIORITY")
	for _, q := range v.Queue {
		fmt.Fprintf(w, "%v\t%v\t%v\t%v\t%v\t%v\n", q["player_id"], q["points"], q["guest"], q["wait_s"], q["band_divisions"], q["priority"])
	}
	if err := w.Flush(); err != nil {
		return err
	}
	for _, p := range v.Pending {
		fmt.Fprintf(t.out, "match %v on server %v: players %v, confirmed %v, deadline %v\n", p["match_id"], p["server_id"], p["players"], p["confirmed"], p["ready_deadline_unix"])
	}
	return nil
}

func (t *tool) annul(ctx context.Context, args []string) error {
	if len(args) < 2 {
		return fmt.Errorf("usage: annul MATCH_ID REASON...")
	}
	var v any
	if err := t.call(ctx, "POST", "/admin/matches/"+args[0]+"/annul", map[string]string{"reason": strings.Join(args[1:], " ")}, &v); err != nil {
		return err
	}
	return t.printJSON(v)
}

func (t *tool) ban(ctx context.Context, args []string) error {
	if len(args) < 1 {
		return fmt.Errorf("usage: ban PLAYER_ID [REASON...]")
	}
	reason := strings.Join(args[1:], " ")
	if reason == "" {
		reason = "admin"
	}
	if err := t.call(ctx, "POST", "/admin/players/"+args[0]+"/ban", map[string]string{"reason": reason}, nil); err != nil {
		return err
	}
	fmt.Fprintf(t.out, "player %s banned\n", args[0])
	return nil
}

func (t *tool) unban(ctx context.Context, args []string) error {
	if len(args) != 1 {
		return fmt.Errorf("usage: unban PLAYER_ID")
	}
	if err := t.call(ctx, "POST", "/admin/players/"+args[0]+"/unban", nil, nil); err != nil {
		return err
	}
	fmt.Fprintf(t.out, "player %s unbanned\n", args[0])
	return nil
}

func (t *tool) drain(ctx context.Context, args []string) error {
	if len(args) < 1 || len(args) > 2 || (len(args) == 2 && args[1] != "off") {
		return fmt.Errorf("usage: drain SERVER_ID [off]")
	}
	on := len(args) == 1
	if err := t.call(ctx, "POST", "/admin/servers/"+args[0]+"/drain", map[string]bool{"drain": on}, nil); err != nil {
		return err
	}
	if on {
		fmt.Fprintf(t.out, "server %s is draining: no new matches; its next heartbeat reply says drain=true\n", args[0])
	} else {
		fmt.Fprintf(t.out, "server %s accepts matches again\n", args[0])
	}
	return nil
}

func (t *tool) replay(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("replay", flag.ContinueOnError)
	fs.SetOutput(t.err)
	file := fs.String("o", "", "output file (default replay-ID.bin)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	id := fs.Arg(0)
	if id == "" {
		return fmt.Errorf("usage: replay [-o FILE] MATCH_ID")
	}
	r, err := t.c.Do(ctx, "GET", "/admin/matches/"+id+"/replay", t.token, nil, nil)
	if err != nil {
		return err
	}
	if !r.OK() {
		return r.Err()
	}
	name := *file
	if name == "" {
		name = "replay-" + id + ".bin"
	}
	if err := os.WriteFile(name, r.Body, 0o600); err != nil {
		return err
	}
	fmt.Fprintf(t.out, "wrote %s (%d bytes, format %s)\n", name, len(r.Body), r.Header.Get("X-Replay-Format"))
	return nil
}
