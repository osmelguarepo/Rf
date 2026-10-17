#!/usr/bin/env bash
# Exports the game as a pack and runs it from the pack alone (docs/GODOT_PLAN.md §6 "Exportación", §8 A3).
#
#   tools/export_check.sh
#   GODOT=/path/to/Godot_v4.7.2-stable_linux.x86_64 tools/export_check.sh
#
# 1. Imports the project as tools/test.sh does (a failed import is retried once), so a fresh clone works too.
# 2. Exports build/fuel_rivals.pck with the "Linux" preset of export_presets.cfg. A pack needs no export templates.
#      timeout 300 godot --headless --path . --export-pack "Linux" build/fuel_rivals.pck
# 3. Reads the pack's file list (the directory of Godot 4.7's pack format, version 4) and fails if the preset's filters
#    did not hold: any file under tests/, tools/ or docs/ (exclude_filter), or no assets/font/OFL.txt (include_filter:
#    the font's licence travels with the font, ASSETS.md). It also needs project.binary.
# 4. Runs the game from the pack with its self test (scripts/app/app.gd), from an empty directory:
#      timeout 300 godot --headless --main-pack <repo>/build/fuel_rivals.pck -- --selftest
#    Godot reads a res:// file the pack lacks from the working directory, so a run from the project directory would
#    pass with a broken pack (one without scripts/view/ did, with WARNING lines only). The run must exit with 0 and
#    print "selftest: ok".
# 5. Fails if the import, the export or the run printed a line starting with "ERROR:" or "SCRIPT ERROR:", as
#    tools/test.sh does. WARNING lines do not count.
#
# On success the last line is "export_check: PASS". The pack stays in build/ (ignored by git).
# Exit codes: 0 passed; 1 the export failed, the pack's file list is wrong or the self test failed; 2 an ERROR line
# while everything else passed; 3 the import failed twice; 64 bad usage; 124 a run took more than 300 s; 127 Godot
# not found; any other code is Godot's own (for example 134 or 139 when it crashes).

set -u -o pipefail

GODOT="${GODOT:-godot}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ERROR_LINE='^(SCRIPT ERROR|ERROR):'
TIMEOUT=300
QUIT_AFTER=3000
PRESET="Linux"
PACK="build/fuel_rivals.pck"
# "GDPC" read as a little-endian u32, and the pack format this script reads.
PACK_MAGIC=1129333831
PACK_FORMAT=4

if [ $# -ne 0 ]; then
	echo "usage: tools/export_check.sh (no arguments; set GODOT to the Godot 4.7.2 binary)" >&2
	exit 64
fi

if ! command -v "$GODOT" >/dev/null 2>&1; then
	echo "export_check.sh: Godot not found: $GODOT (set GODOT to the Godot 4.7.2 binary)" >&2
	exit 127
fi

import_log="$(mktemp)"
export_log="$(mktemp)"
run_log="$(mktemp)"
run_dir="$(mktemp -d)"
trap 'rm -rf "$import_log" "$export_log" "$run_log" "$run_dir"' EXIT

cd "$ROOT" || exit 1

status=0

# fail CODE MESSAGE: reports a failed check. The first failure sets the exit code.
fail() {
	echo "export_check.sh: $2" >&2
	if [ "$status" -eq 0 ]; then
		status="$1"
	fi
}

# u32 FILE OFFSET, u64 FILE OFFSET: the unsigned integer at a byte offset of a file, in the machine's byte order
# (little-endian on x86-64 and ARM, as the pack is).
u32() { od -A n -t u4 -j "$2" -N 4 "$1" | tr -d ' \n'; }
u64() { od -A n -t u8 -j "$2" -N 8 "$1" | tr -d ' \n'; }

# pack_files PACK: the paths in the pack's directory, one per line, without "res://". The header is "GDPC", the
# format version, Godot's major, minor and patch, the flags (u32 each), the file base and the directory's offset
# (u64 each). The directory, at the end of the file: the file count (u32), then for each file the length of its path
# padded to 4 bytes (u32), the path, its offset and size (u64 each), its MD5 (16 bytes) and its flags (u32).
pack_files() {
	local pack="$1" size flags dir count pos len i
	size="$(wc -c <"$pack" | tr -d ' ')"
	if [ "$size" -lt 112 ] || [ "$(u32 "$pack" 0)" != "$PACK_MAGIC" ]; then
		echo "export_check.sh: $pack is not a Godot pack" >&2
		return 1
	fi
	flags="$(u32 "$pack" 20)"
	if [ "$(u32 "$pack" 4)" != "$PACK_FORMAT" ] || [ $((flags & 1)) -ne 0 ]; then
		echo "export_check.sh: cannot read $pack: pack format $(u32 "$pack" 4), flags $flags (this script reads" \
			"format $PACK_FORMAT, written by Godot 4.7, with an unencrypted directory)" >&2
		return 1
	fi
	dir="$(u64 "$pack" 32)"
	if [ "$dir" -lt 112 ] || [ "$dir" -gt $((size - 4)) ]; then
		echo "export_check.sh: cannot read $pack: its directory offset $dir is outside the file" >&2
		return 1
	fi
	count="$(u32 "$pack" "$dir")"
	# An entry takes at least 44 bytes (a path of 1 to 4 bytes).
	if [ "$count" -gt $(((size - dir - 4) / 44)) ]; then
		echo "export_check.sh: cannot read $pack: $count files do not fit in its directory" >&2
		return 1
	fi
	pos=$((dir + 4))
	for ((i = 0; i < count; i++)); do
		len="$(u32 "$pack" "$pos")"
		if [ $((pos + 4 + len + 8 + 8 + 16 + 4)) -gt "$size" ]; then
			echo "export_check.sh: cannot read $pack: entry $i of its directory runs past the end" >&2
			return 1
		fi
		tail -c "+$((pos + 5))" "$pack" | head -c "$len" | tr -d '\0'
		echo
		pos=$((pos + 4 + len + 8 + 8 + 16 + 4))
	done
	if [ "$pos" -ne "$size" ]; then
		echo "export_check.sh: cannot read $pack: its directory of $count files ends at byte $pos of $size" >&2
		return 1
	fi
}

# 1. Import, retried once.
if ! timeout 600 "$GODOT" --headless --path . --import >"$import_log" 2>&1; then
	echo "export_check.sh: the first import failed; importing again" >&2
	if ! timeout 600 "$GODOT" --headless --path . --import >"$import_log" 2>&1; then
		cat "$import_log"
		echo "export_check.sh: the import failed twice" >&2
		exit 3
	fi
fi

# 2. The pack. An old one is removed first, so a failed export cannot leave it to be checked.
mkdir -p "$(dirname "$PACK")"
rm -f "$PACK"
timeout "$TIMEOUT" "$GODOT" --headless --path . --export-pack "$PRESET" "$PACK" >"$export_log" 2>&1
code=$?
if [ "$code" -ne 0 ]; then
	cat "$export_log"
	fail "$code" "the export with the \"$PRESET\" preset failed (exit $code)"
elif [ ! -s "$PACK" ]; then
	cat "$export_log"
	fail 1 "the export with the \"$PRESET\" preset wrote no $PACK"
else
	echo "export_check: exported $PACK with the \"$PRESET\" preset ($(wc -c <"$PACK" | tr -d ' ') bytes)"
fi

if [ -s "$PACK" ]; then
	# 3. What the pack holds.
	if files="$(pack_files "$PACK")"; then
		contents_ok=1
		left_in="$(printf '%s\n' "$files" | grep -E '^(tests|tools|docs)/')"
		if [ -n "$left_in" ]; then
			fail 1 "$PACK has files the preset's exclude_filter leaves out:"
			printf '%s\n' "$left_in" | head -n 20 >&2
			contents_ok=0
		fi
		for required in project.binary assets/font/OFL.txt; do
			if ! printf '%s\n' "$files" | grep -qxF "$required"; then
				fail 1 "$PACK has no $required"
				contents_ok=0
			fi
		done
		if [ "$contents_ok" -eq 1 ]; then
			echo "export_check: $PACK holds $(printf '%s\n' "$files" | grep -c .) files, none under tests/, tools/ or" \
				"docs/, with project.binary and assets/font/OFL.txt"
		fi
	else
		fail 1 "could not read the file list of $PACK"
	fi

	# 4. The game from the pack alone, shown as it runs.
	# --quit-after is a backstop: the self test quits by itself within a few hundred frames, and a pack whose main
	# scene never starts then ends in seconds (and fails for the missing "selftest: ok") instead of at the timeout.
	(cd "$run_dir" && timeout "$TIMEOUT" "$GODOT" --headless --quit-after "$QUIT_AFTER" --main-pack "$ROOT/$PACK" \
		-- --selftest) 2>&1 | tee "$run_log"
	code="${PIPESTATUS[0]}"
	if [ "$code" -ne 0 ]; then
		fail "$code" "the self test from $PACK failed (exit $code)"
	elif ! grep -q '^selftest: ok' "$run_log"; then
		fail 1 "the run from $PACK did not print \"selftest: ok\""
	fi
fi

# 5. Error lines anywhere fail the run, even when everything else passed.
if grep -Eq "$ERROR_LINE" "$import_log" "$export_log" "$run_log"; then
	echo "" >&2
	echo "export_check.sh: ERROR lines in the output:" >&2
	grep -Eh -A2 "$ERROR_LINE" "$import_log" "$export_log" "$run_log" >&2
	if [ "$status" -eq 0 ]; then
		status=2
	fi
fi

if [ "$status" -eq 124 ]; then
	echo "export_check.sh: a run did not finish within $TIMEOUT s" >&2
fi
if [ "$status" -eq 0 ]; then
	echo "export_check: PASS"
fi
exit "$status"
