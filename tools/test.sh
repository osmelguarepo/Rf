#!/usr/bin/env bash
# The single entry point for the tests (docs/GODOT_PLAN.md §6).
#
#   tools/test.sh [--only=PATTERN[,PATTERN...]]
#   GODOT=/path/to/Godot_v4.7.2-stable_linux.x86_64 tools/test.sh
#
# 1. Imports the project. The first import of a fresh clone may fail (GodotSteam's GDExtension, phase B), so a
#    failed import is retried once.
# 2. Runs tests/run_tests.gd headless, with a 600 s timeout. --only= keeps the tests whose id
#    (tests/test_x.gd::test_y) contains a pattern.
# 3. Fails if the import or the test output has a line starting with "ERROR:" or "SCRIPT ERROR:".
#    WARNING lines do not count.
#
# On success the last line is the runner's "N passed, 0 failed".
# Exit codes: 0 all passed; 1 a test failed or none ran; 2 an ERROR line with every test passing; 3 the import
# failed twice; 70 the runner stopped before its end; 124 timeout; 127 Godot not found.

set -u -o pipefail

GODOT="${GODOT:-godot}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ERROR_LINE='^(SCRIPT ERROR|ERROR):'

if ! command -v "$GODOT" >/dev/null 2>&1; then
	echo "test.sh: Godot not found: $GODOT (set GODOT to the Godot 4.7.2 binary)" >&2
	exit 127
fi

import_log="$(mktemp)"
test_log="$(mktemp)"
trap 'rm -f "$import_log" "$test_log"' EXIT

cd "$ROOT" || exit 1

# 1. Import, retried once.
if ! timeout 600 "$GODOT" --headless --path . --import >"$import_log" 2>&1; then
	echo "test.sh: the first import failed; importing again" >&2
	if ! timeout 600 "$GODOT" --headless --path . --import >"$import_log" 2>&1; then
		cat "$import_log"
		echo "test.sh: the import failed twice" >&2
		exit 3
	fi
fi

# 2. Tests, shown as they run.
timeout 600 "$GODOT" --headless --path . -s res://tests/run_tests.gd -- "$@" 2>&1 | tee "$test_log"
status="${PIPESTATUS[0]}"

# 3. Error lines anywhere fail the run, even when every test passed.
if grep -Eq "$ERROR_LINE" "$import_log" "$test_log"; then
	echo "" >&2
	echo "test.sh: ERROR lines in the output:" >&2
	grep -Eh -A2 "$ERROR_LINE" "$import_log" "$test_log" >&2
	if [ "$status" -eq 0 ]; then
		status=2
	fi
fi

if [ "$status" -eq 124 ]; then
	echo "test.sh: the tests did not finish within 600 s" >&2
fi
exit "$status"
