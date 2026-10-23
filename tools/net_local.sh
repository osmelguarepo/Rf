#!/usr/bin/env bash
# A real server and two real clients in three Godot processes on this machine (docs/SPEC_ONLINE.md section 13, M2: "dos
# ventanas en LAN"), over real WebSockets on localhost.
#
#   tools/net_local.sh                 headless: the server, two bot clients and a short match; checks that both clients
#                                      ended in the same state and that the server counted the match
#   tools/net_local.sh --windows       to play it yourself: the server (dev tickets, private rooms) and two game windows
#                                      pointed at it; on both choose ONLINE, then CREATE ROOM on one and the code on the other
#   GODOT=/path/to/Godot_v4.7.2-stable_linux.x86_64 tools/net_local.sh [--port=9181]
#
# For latency and loss on top of localhost use the OS: on Linux `tc qdisc add dev lo root netem delay 60ms 15ms loss 1%`
# (remove it with `tc qdisc del dev lo root`); on Windows, clumsy or a similar tool. tools/net_sim.gd simulates them without
# the network.
# Exit codes: 0 the match ended identically for both clients; 1 it did not; 64 bad usage; 127 Godot not found.

set -u -o pipefail

GODOT="${GODOT:-godot}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT=9181
WINDOWS=0
for argument in "$@"; do
	case "$argument" in
		--port=*) PORT="${argument#--port=}" ;;
		--windows) WINDOWS=1 ;;
		*) echo "usage: tools/net_local.sh [--windows] [--port=N]" >&2; exit 64 ;;
	esac
done

if ! command -v "$GODOT" >/dev/null 2>&1; then
	echo "net_local.sh: Godot not found: $GODOT (set GODOT to the Godot 4.7.2 binary)" >&2
	exit 127
fi

cd "$ROOT" || exit 1
LOGS="$(mktemp -d)"
pids=()
cleanup() {
	for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null; done
	wait 2>/dev/null
}
trap cleanup EXIT

"$GODOT" --headless --path . --import >/dev/null 2>&1

if [ "$WINDOWS" -eq 1 ]; then
	"$GODOT" --headless --path . -s res://scripts/server/server_main.gd -- --port="$PORT" --region=local --dev --max-seconds=1800 >"$LOGS/server.log" 2>&1 &
	pids+=($!)
	sleep 2
	"$GODOT" --path . -- --no-steam --server="ws://127.0.0.1:$PORT" &
	pids+=($!)
	"$GODOT" --path . -- --no-steam --server="ws://127.0.0.1:$PORT" &
	pids+=($!)
	echo "server log: $LOGS/server.log; close both windows to finish"
	wait "${pids[1]}" "${pids[2]}"
	exit 0
fi

# Short races: two 1500 px races, so that the match takes a couple of minutes.
"$GODOT" --headless --path . -s res://scripts/server/server_main.gd -- --port="$PORT" --region=local --dev --race-px=1500 --races=2 --max-seconds=400 >"$LOGS/server.log" 2>&1 &
pids+=($!)
sleep 2
for seat in 0 1; do
	"$GODOT" --headless --path . -s res://tools/net_client.gd -- --server="ws://127.0.0.1:$PORT" --seat=$seat --humans=3 --match="local-$$" --max-seconds=300 >"$LOGS/client$seat.log" 2>&1 &
	pids+=($!)
done
wait "${pids[1]}" "${pids[2]}"
sleep 1
grep -v "^Godot Engine\|^$" "$LOGS/server.log"
grep -h "^client" "$LOGS"/client*.log
sum0="$(grep -o 'confirmed checksum [0-9a-f]*' "$LOGS/client0.log" | tail -1)"
sum1="$(grep -o 'confirmed checksum [0-9a-f]*' "$LOGS/client1.log" | tail -1)"
if [ -n "$sum0" ] && [ "$sum0" = "$sum1" ] && grep -q '^result:' "$LOGS/server.log"; then
	echo "net_local: PASS (both clients ended in the same state: $sum0)"
	exit 0
fi
echo "net_local: FAIL (logs in $LOGS)" >&2
exit 1
