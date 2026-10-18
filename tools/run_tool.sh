#!/usr/bin/env bash
# Runs A2's Godot tools with the error filter of tools/test.sh (docs/GODOT_PLAN.md §6).
#
#   tools/run_tool.sh smoke [ARGUMENT...]         the smoke test, headless (CI runs this one)
#   tools/run_tool.sh screenshots [ARGUMENT...]   the pictures in docs/screenshots/, under xvfb-run
#   tools/run_tool.sh scalecheck                  the whole-number scale, in five windows, under xvfb-run
#   GODOT=/path/to/Godot_v4.7.2-stable_linux.x86_64 tools/run_tool.sh smoke
#
# 1. Imports the project as tools/test.sh does (a failed import is retried once), so a fresh clone works too.
# 2. Runs the tool with the command of plan §6, showing its output as it runs. ARGUMENTs go to the tool after "--".
#      smoke        timeout 300 godot --headless --fixed-fps 60 --path . -s res://tools/smoke.gd -- ARGUMENT...
#                   (with no ARGUMENT: --scenario=1p --frames=10800, then a second run with --scenario=versus)
#      screenshots  xvfb-run -a -s "-screen 0 1920x1080x24" timeout 300 godot --rendering-driver opengl3 \
#                       --fixed-fps 60 --path . -s res://tools/screenshots.gd -- ARGUMENT...
#      scalecheck   the same with tools/scalecheck.gd, once per window: --resolution 1280x800, 1920x1080 and 1366x768
#                   on a 1920x1080 screen (with -- --window=WxH, the size the tool must find); then, with neither, on a
#                   1366x768 and a 1280x800 screen, where the game shrinks its 1920x1080 window to fit
#                   (scripts/app/app.gd fit_window()).
# 3. Fails if the import or the tool printed a line starting with "ERROR:" or "SCRIPT ERROR:", as tools/test.sh does.
#    That includes what Godot prints after the tool has quit, while it shuts down (leaked RIDs, resources still in use
#    at exit), which the tool's own count of logged errors (tools/tool_base.gd) cannot see. WARNING lines do not count.
#
# On success the last line is the tool's verdict: "smoke: PASS", "screenshots: saved ..." or
# "scalecheck: 5 windows passed".
# Exit codes: 0 passed; 1 the tool failed; 2 an ERROR line while the tool passed; 3 the import failed twice;
# 64 bad usage; 124 a run took more than 300 s; 127 Godot or xvfb-run not found.

set -u -o pipefail

GODOT="${GODOT:-godot}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ERROR_LINE='^(SCRIPT ERROR|ERROR):'
TIMEOUT=300

usage() {
	echo "usage: tools/run_tool.sh smoke|screenshots|scalecheck [ARGUMENT...]" >&2
	exit 64
}

[ $# -ge 1 ] || usage
tool="$1"
shift
case "$tool" in
	smoke | screenshots) ;;
	scalecheck) [ $# -eq 0 ] || usage ;;
	*) usage ;;
esac

if ! command -v "$GODOT" >/dev/null 2>&1; then
	echo "run_tool.sh: Godot not found: $GODOT (set GODOT to the Godot 4.7.2 binary)" >&2
	exit 127
fi
if [ "$tool" != smoke ] && ! command -v xvfb-run >/dev/null 2>&1; then
	echo "run_tool.sh: $tool needs a display: install xvfb-run (Debian and Ubuntu package xvfb)" >&2
	exit 127
fi

import_log="$(mktemp)"
tool_log="$(mktemp)"
trap 'rm -f "$import_log" "$tool_log"' EXIT

cd "$ROOT" || exit 1

# 1. Import, retried once.
if ! timeout 600 "$GODOT" --headless --path . --import >"$import_log" 2>&1; then
	echo "run_tool.sh: the first import failed; importing again" >&2
	if ! timeout 600 "$GODOT" --headless --path . --import >"$import_log" 2>&1; then
		cat "$import_log"
		echo "run_tool.sh: the import failed twice" >&2
		exit 3
	fi
fi

# 2. The tool, shown as it runs. The first run that fails sets the exit code.
status=0
runs=0

run() {
	"$@" 2>&1 | tee -a "$tool_log"
	local code="${PIPESTATUS[0]}"
	runs=$((runs + 1))
	if [ "$code" -ne 0 ] && [ "$status" -eq 0 ]; then
		status="$code"
	fi
}

# on_screen WxH GODOT_ARGUMENT...: Godot with a renderer, on a virtual screen of that size.
on_screen() {
	local screen="$1"
	shift
	run xvfb-run -a -s "-screen 0 ${screen}x24" timeout "$TIMEOUT" "$GODOT" --rendering-driver opengl3 --fixed-fps 60 "$@"
}

case "$tool" in
	smoke)
		if [ $# -eq 0 ]; then
			run timeout "$TIMEOUT" "$GODOT" --headless --fixed-fps 60 --path . -s res://tools/smoke.gd -- --scenario=1p --frames=10800
			run timeout "$TIMEOUT" "$GODOT" --headless --fixed-fps 60 --path . -s res://tools/smoke.gd -- --scenario=versus
		else
			run timeout "$TIMEOUT" "$GODOT" --headless --fixed-fps 60 --path . -s res://tools/smoke.gd -- "$@"
		fi
		;;
	screenshots)
		on_screen 1920x1080 --path . -s res://tools/screenshots.gd -- "$@"
		;;
	scalecheck)
		for size in 1280x800 1920x1080 1366x768; do
			on_screen 1920x1080 --resolution "$size" --path . -s res://tools/scalecheck.gd -- --window="$size"
		done
		for screen in 1366x768 1280x800; do
			on_screen "$screen" --path . -s res://tools/scalecheck.gd
		done
		;;
esac

# 3. Error lines anywhere fail the run, even when the tool passed.
if grep -Eq "$ERROR_LINE" "$import_log" "$tool_log"; then
	echo "" >&2
	echo "run_tool.sh: ERROR lines in the output:" >&2
	grep -Eh -A2 "$ERROR_LINE" "$import_log" "$tool_log" >&2
	if [ "$status" -eq 0 ]; then
		status=2
	fi
fi

if [ "$status" -eq 124 ]; then
	echo "run_tool.sh: a run of $tool did not finish within $TIMEOUT s" >&2
fi
if [ "$tool" = scalecheck ] && [ "$status" -eq 0 ]; then
	echo "scalecheck: $runs windows passed"
fi
exit "$status"
