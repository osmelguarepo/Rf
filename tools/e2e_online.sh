#!/usr/bin/env bash
# The whole online stack on this machine, for real (docs/SPEC_ONLINE.md "E2E: verificado en localhost"): PostgreSQL, the Go API
# and matchmaker, a headless Godot game server that registers itself with the API, and headless Godot clients that use the real
# client classes (ApiClient, LoginFlow, Matchmaking, OnlineSession over WebSockets; tools/net_queue_client.gd).
#
#   GODOT=/path/to/godot-console tools/e2e_online.sh [pair] [solo] [abandon] [guests]      (no argument: all four)
#
#   pair     two Steam stand-in accounts (distinct /24 through X-Forwarded-For) find each other in the queue, ready check, a
#            3-race match against each other and bots; ranked: the points must change; checksums, result, replay checked
#   solo     one guest, filled with bots after QUEUE_SOLO_WAIT; unranked, no points
#   abandon  two Steam accounts; one drops the connection in the middle of the race and calls /match/{id}/leave: the abandon
#            is counted (match_players.abandoned) and the other one still ends the match and is the only one who scores
#   guests   two guests: a match with two humans that is not ranked (guests never score)
#
# Environment (defaults in brackets): GODOT, FUEL_TOOLS [C:/Users/osmel/AppData/Local/Temp/fuel-tools: go-x, pg-x, pgdata],
# PG_PORT [54329], API_PORT [18080], GAME_PORT [19080], E2E_FULL=1 plays the real race length instead of 1500 px races,
# E2E_KEEP=1 keeps the logs directory. It creates and drops its own database, builds the API into the temp directory, and
# stops every process it started (also on Ctrl-C). Exit code 0: every check of every scenario passed.

set -u -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-/c/Users/osmel/Downloads/Godot_v4.7.2-stable_win64_console.exe}"
FUEL_TOOLS="${FUEL_TOOLS:-/c/Users/osmel/AppData/Local/Temp/fuel-tools}"
PG_PORT="${PG_PORT:-54329}"
API_PORT="${API_PORT:-18080}"
GAME_PORT="${GAME_PORT:-19080}"
GO="$FUEL_TOOLS/go-x/go/bin/go.exe"
PGBIN="$FUEL_TOOLS/pg-x/pgsql/bin"
ADMIN_TOKEN="e2e-admin-token-0123456789abcdef"
REGISTER_TOKEN="e2e-register-token-0123456789ab"
METRICS_TOKEN="e2e-metrics-token-0123456789"
API_URL="http://127.0.0.1:$API_PORT"
PGURL_BASE="postgres://postgres@localhost:$PG_PORT"
USERDIR="${APPDATA:-}/Godot/app_userdata/Fuel Rivals"

for tool in "$GODOT" "$GO" "$PGBIN/psql.exe"; do
	if [ ! -x "$tool" ]; then echo "e2e_online: missing tool: $tool (set GODOT / FUEL_TOOLS)" >&2; exit 127; fi
done

LOGS="$(mktemp -d)"
pids=()
FAILED=0
CHECKS=0
DB=""

psql() { "$PGBIN/psql.exe" -h localhost -p "$PG_PORT" -U postgres -qAtX "$@"; }

stop_all() {
	local pid
	for pid in "${pids[@]:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; done
	sleep 1
	for pid in "${pids[@]:-}"; do [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null; done
	pids=()
}
cleanup() {
	stop_all
	if [ -n "$DB" ]; then psql -d postgres -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)" >/dev/null 2>&1; fi
	if [ "${E2E_KEEP:-0}" = "1" ]; then echo "logs kept in $LOGS"; else rm -rf "$LOGS"; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

check() { # check "what" <test command...>
	local what="$1"; shift
	CHECKS=$((CHECKS + 1))
	if "$@"; then echo "  ok    $what"; else echo "  FAIL  $what"; FAILED=$((FAILED + 1)); fi
}
eq() { [ "$1" = "$2" ]; }
nonempty() { [ -n "$1" ]; }

# --- PostgreSQL ---------------------------------------------------------------------------------------------------------------

if ! "$PGBIN/pg_isready.exe" -h localhost -p "$PG_PORT" >/dev/null 2>&1; then
	echo "e2e_online: starting PostgreSQL on port $PG_PORT"
	"$PGBIN/pg_ctl.exe" -D "$(cygpath -w "$FUEL_TOOLS/pgdata")" -o "-p $PG_PORT" -l "$(cygpath -w "$FUEL_TOOLS/pg.log")" -w start >/dev/null || { echo "cannot start PostgreSQL" >&2; exit 1; }
fi

# --- Build ----------------------------------------------------------------------------------------------------------------------

echo "e2e_online: building the API"
(cd "$ROOT/backend" && PATH="$(dirname "$GO"):$PATH" "$GO" build -o "$(cygpath -w "$LOGS/api.exe")" ./cmd/api) || { echo "build failed" >&2; exit 1; }
(cd "$ROOT/backend" && PATH="$(dirname "$GO"):$PATH" "$GO" build -o "$(cygpath -w "$LOGS/loadbot.exe")" ./cmd/loadbot) || { echo "loadbot build failed" >&2; exit 1; }
"$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1

# --- One stack per scenario -----------------------------------------------------------------------------------------------------

start_stack() { # start_stack NAME
	NAME="$1"
	DB="fuel_e2e_$$_$NAME"
	psql -d postgres -c "CREATE DATABASE $DB" >/dev/null || { echo "cannot create database" >&2; exit 1; }
	rm -rf "$USERDIR/outbox"   # results of an earlier run must not be sent to this database
	env DATABASE_URL="$PGURL_BASE/$DB?sslmode=disable" PUBLIC_URL="http://localhost:$API_PORT" LISTEN_ADDR="127.0.0.1:$API_PORT" \
		MASTER_KEY="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" \
		BAN_SALT="e2e-ban-salt-0123456789" ADMIN_TOKEN="$ADMIN_TOKEN" SERVER_REGISTER_TOKEN="$REGISTER_TOKEN" METRICS_TOKEN="$METRICS_TOKEN" \
		TRUST_PROXY=true DEV_FAKE_STEAM=1 RATE_GUEST_PER_HOUR=1000 RATE_LOGIN_PER_MIN=1000 RATE_ACCOUNT_PER_MIN=6000 \
		QUEUE_MAX_WAIT="${QWAIT:-4}" QUEUE_SOLO_WAIT="${QWAIT:-4}" QUEUE_BAND_STEP=10 READY_SECONDS=15 LEASE_TTL=30s LOG_LEVEL=info \
		"$LOGS/api.exe" >"$LOGS/$NAME.api.log" 2>&1 &
	pids+=($!)
	local i
	for i in $(seq 1 50); do curl -sf "$API_URL/healthz" >/dev/null 2>&1 && break; sleep 0.2; done
	curl -sf "$API_URL/healthz" >/dev/null || { echo "the API did not start:"; tail -5 "$LOGS/$NAME.api.log"; exit 1; }
	local tuning=(--race-px=1500 --races=3)
	[ "${E2E_FULL:-0}" = "1" ] && tuning=()
	"$GODOT" --headless --path "$ROOT" -s res://scripts/server/server_main.gd -- --port="$GAME_PORT" --region=default \
		--api="$API_URL" --server-id=e2e-1 --register-token="$REGISTER_TOKEN" --public-url="ws://127.0.0.1:$GAME_PORT" --capacity="${CAPACITY:-8}" \
		--max-seconds=1500 "${tuning[@]}" >"$LOGS/$NAME.server.log" 2>&1 &
	pids+=($!)
	for i in $(seq 1 100); do grep -q "registered as id" "$LOGS/$NAME.server.log" 2>/dev/null && break; sleep 0.2; done
	grep -q "registered as id" "$LOGS/$NAME.server.log" || { echo "the game server did not register:"; cat "$LOGS/$NAME.server.log"; exit 1; }
}

stop_stack() {
	stop_all
	psql -d postgres -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)" >/dev/null 2>&1
	DB=""
}

client() { # client LABEL OPTIONS... -> background, log in $LOGS/$NAME.LABEL.log
	local label="$1"; shift
	"$GODOT" --headless --path "$ROOT" -s res://tools/net_queue_client.gd -- --api="$API_URL" --label="$label" "$@" >"$LOGS/$NAME.$label.log" 2>&1 &
	CLIENT_PIDS+=($!)
	pids+=($!)
}

wait_clients() { # waits for the clients started since the last call; sets CLIENT_STATUS (space separated exit codes)
	local pid status=""
	for pid in "${CLIENT_PIDS[@]}"; do
		wait "$pid"; status="$status $?"
	done
	CLIENT_STATUS="$status"
	CLIENT_PIDS=()
}
CLIENT_PIDS=()
CLIENT_STATUS=""

field() { # field LABEL REGEX: the first capture group of the last matching line of that client's log
	grep -o "$2" "$LOGS/$NAME.$1.log" | tail -1
}
q() { psql -d "$DB" -c "$1"; }

wait_settled() { # wait until the API has the match settled and its replay (the server's outbox retries)
	local mid="$1" i
	for i in $(seq 1 60); do
		if [ "$(q "SELECT status FROM matches WHERE match_id=$mid")" = "settled" ] && [ "$(q "SELECT count(*) FROM replays WHERE match_id=$mid")" != "0" ]; then return 0; fi
		sleep 1
	done
	return 1
}

server_checksum() { grep -o '"final_checksum":"[0-9a-f]*"' "$LOGS/$NAME.server.log" | tail -1 | sed 's/.*:"\(.*\)"/\1/'; }
client_checksum() { grep -o 'confirmed checksum [0-9a-f]*' "$LOGS/$NAME.$1.log" | tail -1 | awk '{print $3}'; }
client_match() { grep -o 'ended. match [0-9]*' "$LOGS/$NAME.$1.log" | tail -1 | awk '{print $3}'; }

show_logs() {
	echo "  --- logs of $NAME ---"
	grep -h "^qclient" "$LOGS/$NAME".*.log 2>/dev/null | head -60
	grep -v "^Godot Engine\|^$" "$LOGS/$NAME.server.log" | head -40
}

# --- Scenarios ------------------------------------------------------------------------------------------------------------------

scenario_pair() {
	echo "== pair: two Steam accounts, a ranked 3-race match through the real queue"
	start_stack pair
	client A --steam=76561198000000001 --xff=10.1.1.1
	client B --steam=76561198000000002 --xff=10.2.2.2
	wait_clients
	check "both clients exited 0" eq "$CLIENT_STATUS" " 0 0"
	local mid; mid="$(client_match A)"; mid="${mid:-0}"
	check "both clients report the same match id" eq "$mid" "$(client_match B)"
	check "a match id was assigned by the API" nonempty "$mid"
	local ca cb cs; ca="$(client_checksum A)"; cb="$(client_checksum B)"; cs="$(server_checksum)"
	check "client A confirmed checksum is not empty" nonempty "$ca"
	check "client A and client B confirmed checksums are equal" eq "$ca" "$cb"
	check "the confirmed checksum equals the server's final checksum" eq "$ca" "$cs"
	check "the API settled the match and stored the replay" wait_settled "$mid"
	check "match is ranked with 2 humans and 4 bots" eq "$(q "SELECT ranked||' '||humans||' '||bots FROM matches WHERE match_id=$mid")" "true 2 4"
	check "both human seats have a reported place" eq "$(q "SELECT count(*) FROM match_players WHERE match_id=$mid AND reported_place IS NOT NULL AND abandoned=false")" "2"
	check "ranking points changed (somebody scored)" eq "$(q "SELECT (sum(applied_delta)<>0)::text FROM match_players WHERE match_id=$mid")" "true"
	check "players.points equals points_after" eq "$(q "SELECT count(*) FROM match_players m JOIN ratings p USING (player_id) WHERE m.match_id=$mid AND p.points<>m.points_after")" "0"
	check "the replay is stored with the Godot format" eq "$(q "SELECT format FROM replays WHERE match_id=$mid")" "godot-replay-1"
	check "the server outbox is empty (everything accepted)" eq "$(ls "$USERDIR/outbox" 2>/dev/null | grep -vc '^failed$')" "0"
	check "the API counted one finished match in the funnel" eq "$(curl -s -H "Authorization: Bearer $METRICS_TOKEN" "$API_URL/metrics" | grep -c '^fr_funnel_total{stage="finished"} 2$')" "1"
	echo "  rank_reason: $(q "SELECT rank_reason FROM matches WHERE match_id=$mid")"
	echo "  match $mid: $(q "SELECT string_agg(seat||':'||final_place||':'||points_before||'->'||points_after, ' ' ORDER BY seat) FROM match_players WHERE match_id=$mid")"
	[ "$FAILED" -gt 0 ] && show_logs
	stop_stack
}

scenario_solo() {
	echo "== solo: one guest, filled with bots after the solo wait, unranked"
	start_stack solo
	client S
	wait_clients
	check "the client exited 0" eq "$CLIENT_STATUS" " 0"
	local mid; mid="$(client_match S)"; mid="${mid:-0}"
	check "a match id was assigned" nonempty "$mid"
	check "client and server checksums are equal" eq "$(client_checksum S)" "$(server_checksum)"
	check "the API settled the match and stored the replay" wait_settled "$mid"
	check "match is unranked with 1 human and 5 bots" eq "$(q "SELECT ranked||' '||humans||' '||bots FROM matches WHERE match_id=$mid")" "false 1 5"
	check "no points were applied" eq "$(q "SELECT coalesce(sum(applied_delta),0) FROM match_players WHERE match_id=$mid")" "0"
	check "the guest has 0 points" eq "$(field S 'final profile points [0-9-]*' | awk '{print $4}')" "0"
	[ "$FAILED" -gt 0 ] && show_logs
	stop_stack
}

scenario_guests() {
	echo "== guests: two guests, two humans, not ranked"
	start_stack guests
	client G1 --xff=10.3.3.3
	client G2 --xff=10.4.4.4
	wait_clients
	check "both clients exited 0" eq "$CLIENT_STATUS" " 0 0"
	local mid; mid="$(client_match G1)"; mid="${mid:-0}"
	check "both in the same match" eq "$mid" "$(client_match G2)"
	check "confirmed checksums equal the server's" eq "$(client_checksum G1)-$(client_checksum G2)" "$(server_checksum)-$(server_checksum)"
	check "the API settled the match" wait_settled "$mid"
	check "match is unranked with 2 humans and 4 bots" eq "$(q "SELECT ranked||' '||humans||' '||bots FROM matches WHERE match_id=$mid")" "false 2 4"
	check "no points were applied" eq "$(q "SELECT coalesce(sum(applied_delta),0) FROM match_players WHERE match_id=$mid")" "0"
	[ "$FAILED" -gt 0 ] && show_logs
	stop_stack
}

scenario_abandon() {
	echo "== abandon: one of two Steam accounts drops the connection in the middle of the race"
	start_stack abandon
	client A --steam=76561198000000011 --xff=10.1.1.1
	client Q --steam=76561198000000012 --xff=10.2.2.2 --abandon-after=12
	wait_clients
	check "both clients exited 0" eq "$CLIENT_STATUS" " 0 0"
	local mid; mid="$(client_match A)"; mid="${mid:-0}"
	check "the staying client finished a match" nonempty "$mid"
	check "the staying client's checksum equals the server's" eq "$(client_checksum A)" "$(server_checksum)"
	check "the API settled the match" wait_settled "$mid"
	check "exactly one abandon was stored" eq "$(q "SELECT count(*) FROM match_players WHERE match_id=$mid AND abandoned")" "1"
	check "the quitter has a left_at / strike" eq "$(q "SELECT count(*) FROM leave_strikes")" "1"
	check "the player who stayed did not abandon and scored" eq "$(q "SELECT count(*) FROM match_players WHERE match_id=$mid AND NOT abandoned AND applied_delta>0")" "1"
	check "the replay is stored" eq "$(q "SELECT count(*) FROM replays WHERE match_id=$mid")" "1"
	echo "  match $mid: $(q "SELECT ranked||' '||rank_reason FROM matches WHERE match_id=$mid"); $(q "SELECT string_agg(seat||':abandoned='||abandoned||':'||points_before||'->'||points_after, ' ' ORDER BY seat) FROM match_players WHERE match_id=$mid")"
	[ "$FAILED" -gt 0 ] && show_logs
	stop_stack
}

scenario_load() {
	echo "== load: ${LOAD_N:-100} guests with the Go loadbot against the API and the real Godot server (queue, ready, ticket; they do not drive)"
	CAPACITY=1000 QWAIT=30 start_stack load
	"$LOGS/loadbot.exe" -url "$API_URL" -n "${LOAD_N:-100}" -ramp "${LOAD_RAMP:-120s}" -region default -timeout "${LOAD_TIMEOUT:-5m}" -quiet >"$LOGS/load.report.json" 2>"$LOGS/load.err"
	cat "$LOGS/load.report.json"; tail -5 "$LOGS/load.err"
	echo "  matches: $(q "SELECT count(*)||' total, '||coalesce(sum(bots),0)||' bot seats, '||count(*) FILTER (WHERE bots>0)||' with bots' FROM matches")"
	echo "  server heartbeats ok / API 5xx: $(grep -c heartbeat "$LOGS/load.api.log") / $(grep -c '"status":5' "$LOGS/load.api.log")"
	stop_stack
}

scenarios=("$@")
[ "${#scenarios[@]}" -eq 0 ] && scenarios=(pair solo abandon guests)
for s in "${scenarios[@]}"; do
	case "$s" in
		pair|solo|abandon|guests|load) "scenario_$s" ;;
		*) echo "usage: tools/e2e_online.sh [pair] [solo] [abandon] [guests]" >&2; exit 64 ;;
	esac
done

if [ "$FAILED" -eq 0 ]; then echo "e2e_online: PASS ($CHECKS checks)"; exit 0; fi
echo "e2e_online: FAIL ($FAILED of $CHECKS checks failed; E2E_KEEP=1 keeps the logs)" >&2
exit 1
