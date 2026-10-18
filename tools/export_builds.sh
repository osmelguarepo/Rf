#!/usr/bin/env bash
# Exports the four release builds and checks them (docs/GODOT_PLAN.md §6 "Exportación" B3, §8 B3; docs/HANDOFF.md B4
# "For B3: the Steam and non-Steam builds").
#
#   tools/export_builds.sh
#   GODOT=/path/to/Godot_v4.7.2-stable_linux.x86_64 tools/export_builds.sh
#
# 1. Installs the export templates if they are missing (tools/fetch_templates.py: four files of the official 4.7.2
#    templates, checked by size and CRC-32).
# 2. Imports the project as tools/test.sh does (a failed import is retried once), so a fresh clone works too.
# 3. Exports the presets of export_presets.cfg with their release templates, each into its own folder:
#      build/linux/fuel_rivals.x86_64           "Linux"            (no Steam)
#      build/windows/fuel_rivals.exe            "Windows Desktop"  (no Steam)
#      build/linux_steam/fuel_rivals.x86_64     "Linux Steam"      (GodotSteam and libsteam_api.so next to it)
#      build/windows_steam/fuel_rivals.exe      "Windows Steam"    (GodotSteam and steam_api64.dll next to it)
#    The pack is embedded in each executable (embed_pck).
# 4. Copies next to every executable what a player's copy needs besides the game: OFL.txt (the font's licence) and
#    ASSETS.md (credits and licences); next to the Steam builds also steam_input/ (the Steam Input action manifest and
#    its controller layouts, read from <exe dir>/steam_input/) and godotsteam_license.md (MIT). Never steam_appid.txt.
# 5. Checks each build:
#    - Linux: the executable runs from an empty directory with its self test (-- --selftest, which also plays a
#      versus race through the screens) and prints "selftest: ok", and runs headless for 300 frames (--quit-after 300).
#      The Steam build must find its libraries (an ERROR line otherwise); without a Steam client it warns once.
#    - Windows: the executable and the Steam DLLs are PE32+ x86-64 files (they cannot run here).
#    - The Steam builds have their libraries, the non-Steam builds have none.
# 6. Fails on any line starting with "ERROR:" or "SCRIPT ERROR:" in the import, the exports or the runs.
#
# On success the last line is "export_builds: PASS". The builds stay in build/ (ignored by git).
# Exit codes: 0 passed; 1 an export or a check failed; 2 an ERROR line while everything else passed; 3 the import
# failed twice; 4 the templates could not be installed; 64 bad usage; 124 a run took more than 300 s; 127 Godot not
# found.

set -u -o pipefail

GODOT="${GODOT:-godot}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ERROR_LINE='^(SCRIPT ERROR|ERROR):'
TIMEOUT=300
TEMPLATES="${HOME}/.local/share/godot/export_templates/4.7.2.stable"
# preset name | output path | kind
BUILDS=(
	"Linux|build/linux/fuel_rivals.x86_64|linux"
	"Windows Desktop|build/windows/fuel_rivals.exe|windows"
	"Linux Steam|build/linux_steam/fuel_rivals.x86_64|linux_steam"
	"Windows Steam|build/windows_steam/fuel_rivals.exe|windows_steam"
)

if [ $# -ne 0 ]; then
	echo "usage: tools/export_builds.sh (no arguments; set GODOT to the Godot 4.7.2 binary)" >&2
	exit 64
fi

if ! command -v "$GODOT" >/dev/null 2>&1; then
	echo "export_builds.sh: Godot not found: $GODOT (set GODOT to the Godot 4.7.2 binary)" >&2
	exit 127
fi

logs="$(mktemp -d)"
run_dir="$(mktemp -d)"
trap 'rm -rf "$logs" "$run_dir"' EXIT

cd "$ROOT" || exit 1

status=0

# fail CODE MESSAGE: reports a failed check. The first failure sets the exit code.
fail() {
	echo "export_builds.sh: $2" >&2
	if [ "$status" -eq 0 ]; then
		status="$1"
	fi
}

# 1. Templates.
for file in version.txt linux_release.x86_64 windows_release_x86_64.exe; do
	if [ ! -f "$TEMPLATES/$file" ]; then
		echo "export_builds: installing the export templates into $TEMPLATES"
		if ! python3 -I tools/fetch_templates.py "$TEMPLATES"; then
			echo "export_builds.sh: the export templates could not be installed" >&2
			exit 4
		fi
		break
	fi
done

# 2. Import, retried once.
if ! timeout "$TIMEOUT" "$GODOT" --headless --path . --import >"$logs/import.log" 2>&1; then
	echo "export_builds.sh: the first import failed; importing again" >&2
	if ! timeout "$TIMEOUT" "$GODOT" --headless --path . --import >"$logs/import.log" 2>&1; then
		cat "$logs/import.log"
		echo "export_builds.sh: the import failed twice" >&2
		exit 3
	fi
fi

# is_pe64 FILE: true if FILE is a PE32+ x86-64 image.
is_pe64() {
	python3 -I - "$1" <<'PY'
import struct, sys
data = open(sys.argv[1], "rb").read(4096)
if data[:2] != b"MZ":
    sys.exit(1)
pe = struct.unpack_from("<I", data, 0x3C)[0]
ok = data[pe:pe + 4] == b"PE\0\0" and struct.unpack_from("<H", data, pe + 4)[0] == 0x8664 \
    and struct.unpack_from("<H", data, pe + 24)[0] == 0x20B
sys.exit(0 if ok else 1)
PY
}

for entry in "${BUILDS[@]}"; do
	IFS='|' read -r preset out kind <<<"$entry"
	dir="$(dirname "$out")"
	rm -rf "$dir"
	mkdir -p "$dir"

	# 3. Export.
	log="$logs/export_$kind.log"
	timeout "$TIMEOUT" "$GODOT" --headless --path . --export-release "$preset" "$out" >"$log" 2>&1
	code=$?
	if [ "$code" -ne 0 ] || [ ! -s "$out" ]; then
		cat "$log"
		fail 1 "the export of \"$preset\" failed (exit $code)"
		continue
	fi

	# 4. What travels with the executable.
	cp assets/font/OFL.txt "$dir/OFL.txt"
	cp ASSETS.md "$dir/ASSETS.md"
	case "$kind" in
	*_steam)
		mkdir -p "$dir/steam_input"
		cp steam_input/*.vdf "$dir/steam_input/"
		cp addons/godotsteam/license.md "$dir/godotsteam_license.md"
		;;
	esac

	# 5. Checks.
	case "$kind" in
	linux) libs=() ;;
	linux_steam) libs=(libgodotsteam.linux.template_release.x86_64.so libsteam_api.so) ;;
	windows) libs=() ;;
	windows_steam) libs=(libgodotsteam.windows.template_release.x86_64.dll steam_api64.dll) ;;
	esac
	for lib in "${libs[@]}"; do
		[ -f "$dir/$lib" ] || fail 1 "$dir has no $lib"
	done
	if [ "${#libs[@]}" -eq 0 ] && ls "$dir" | grep -qiE 'godotsteam|steam_api'; then
		fail 1 "$dir is a build without Steam but holds Steam libraries"
	fi

	case "$kind" in
	linux | linux_steam)
		exe="$ROOT/$out"
		(cd "$run_dir" && timeout "$TIMEOUT" "$exe" --headless -- --selftest) >"$logs/run_$kind.log" 2>&1
		code=$?
		if [ "$code" -ne 0 ]; then
			cat "$logs/run_$kind.log"
			fail "$code" "the self test of $out failed (exit $code)"
		elif ! grep -q '^selftest: ok' "$logs/run_$kind.log"; then
			fail 1 "$out did not print \"selftest: ok\""
		fi
		(cd "$run_dir" && timeout "$TIMEOUT" "$exe" --headless --quit-after 300) >"$logs/quit_$kind.log" 2>&1
		code=$?
		[ "$code" -eq 0 ] || fail "$code" "$out --headless --quit-after 300 exited with $code"
		;;
	windows | windows_steam)
		is_pe64 "$out" || fail 1 "$out is not a PE32+ x86-64 executable"
		for lib in "${libs[@]}"; do
			[ -f "$dir/$lib" ] && { is_pe64 "$dir/$lib" || fail 1 "$dir/$lib is not a PE32+ x86-64 library"; }
		done
		;;
	esac
	echo "export_builds: $preset -> $out ($(du -h "$out" | cut -f1)), with $(ls "$dir" | grep -vc "$(basename "$out")") more files"
	grep -h '^selftest:' "$logs/run_$kind.log" 2>/dev/null | sed "s/^/export_builds:   /"
done

# 6. Error lines anywhere fail the run.
if grep -Eq "$ERROR_LINE" "$logs"/*.log; then
	echo "" >&2
	echo "export_builds.sh: ERROR lines in the output:" >&2
	grep -Eh -A2 "$ERROR_LINE" "$logs"/*.log >&2
	if [ "$status" -eq 0 ]; then
		status=2
	fi
fi

if [ "$status" -eq 124 ]; then
	echo "export_builds.sh: a run did not finish within $TIMEOUT s" >&2
fi
if [ "$status" -eq 0 ]; then
	echo "export_builds: PASS"
fi
exit "$status"
