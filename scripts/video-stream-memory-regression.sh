#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/WallpaperMac.app"
EXEC="$APP/Contents/MacOS/WallpaperMac"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wallpapermac-stream-memory.XXXXXX")"
LIBRARY="$TEST_ROOT/Library"
SOURCE="$TEST_ROOT/large-stream.mp4"
DEFAULTS_BACKUP="$TEST_ROOT/defaults.plist"
DEFAULTS_BACKED_UP=0
RUN_PID=""

cleanup() {
    if [[ -n "$RUN_PID" ]] && kill -0 "$RUN_PID" 2>/dev/null; then
        kill "$RUN_PID" 2>/dev/null || true
        for _ in {1..20}; do
            kill -0 "$RUN_PID" 2>/dev/null || break
            sleep 0.2
        done
        kill -9 "$RUN_PID" 2>/dev/null || true
    fi
    if (( DEFAULTS_BACKED_UP )); then
        defaults import com.wallpaper.mac "$DEFAULTS_BACKUP" >/dev/null 2>&1 || true
    else
        defaults delete com.wallpaper.mac 'WallpaperMac.libraryPath' >/dev/null 2>&1 || true
        defaults delete com.wallpaper.mac 'WallpaperMac.onboardingCompleted' >/dev/null 2>&1 || true
    fi
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT INT TERM

FFMPEG="${WALLPAPERMAC_FFMPEG:-/opt/homebrew/bin/ffmpeg}"
[[ -x "$FFMPEG" ]] || { echo "ffmpeg not found: $FFMPEG" >&2; exit 1; }
test -x "$EXEC"

defaults export com.wallpaper.mac "$DEFAULTS_BACKUP" >/dev/null 2>&1 && DEFAULTS_BACKED_UP=1
mkdir -p "$LIBRARY/Assets"

echo '== Build long streaming fixture =='
"$FFMPEG" -hide_banner -loglevel error -y \
    -f lavfi -i 'testsrc2=size=640x360:rate=30' \
    -t 20 -c:v libsvtav1 -preset 10 -pix_fmt yuv420p "$SOURCE"

cat > "$TEST_ROOT/list-screens.swift" <<'SWIFT'
import AppKit
for screen in NSScreen.screens {
    let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    print("\(number?.stringValue ?? "0")\t\(screen.localizedName)")
}
SWIFT
/usr/bin/swiftc "$TEST_ROOT/list-screens.swift" -o "$TEST_ROOT/list-screens" -framework AppKit >/dev/null
SCREEN_INFO="$("$TEST_ROOT/list-screens" | head -1)"
DISPLAY_NUMBER="$(print -r -- "$SCREEN_INFO" | awk -F '\t' '{print $1}')"
DISPLAY_NAME="$(print -r -- "$SCREEN_INFO" | awk -F '\t' '{print $2}')"

python3 - "$LIBRARY" "$SOURCE" "$DISPLAY_NUMBER" "$DISPLAY_NAME" <<'PY'
import json, sys, uuid
from datetime import datetime, timezone
from pathlib import Path
library, source, display_number, display_name = map(Path, sys.argv[1:3]) if False else (Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4])
now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace('+00', 'Z')
item = {
    'id': str(uuid.uuid4()).upper(),
    'name': 'Long Streaming Fixture',
    'type': 'video',
    'sourceURL': source.as_uri(),
    'storageMode': 'externalReference',
    'availability': 'available',
    'createdAt': now,
    'isFavorite': False,
}
(library / 'wallpapers.json').write_text(json.dumps([item], separators=(',', ':')))
(library / 'display-assignments.json').write_text(json.dumps([{
    'id': f'display-{display_number}',
    'displayName': display_name,
    'isConnected': True,
    'wallpaperID': item['id'],
    'applicationState': 'applied',
}], separators=(',', ':')))
PY

defaults write com.wallpaper.mac 'WallpaperMac.libraryPath' -string "$LIBRARY"
defaults write com.wallpaper.mac 'WallpaperMac.onboardingCompleted' -bool YES

echo '== Measure streaming RSS =='
"$EXEC" >"$TEST_ROOT/app.log" 2>&1 &
RUN_PID=$!
sleep 5
kill -0 "$RUN_PID" 2>/dev/null || { echo "WallpaperMac exited during streaming memory test" >&2; cat "$TEST_ROOT/app.log" >&2; exit 1; }

BASELINE="$(ps -o rss= -p "$RUN_PID" | tr -d ' ')"
SAMPLES="$TEST_ROOT/rss.txt"
for _ in {1..15}; do
    ps -o rss= -p "$RUN_PID" | tr -d ' ' >> "$SAMPLES"
    sleep 1
done

python3 - "$BASELINE" "$SAMPLES" <<'PY'
import sys
from pathlib import Path
baseline = int(sys.argv[1])
samples = [int(line) for line in Path(sys.argv[2]).read_text().splitlines() if line.strip()]
end = samples[-1]
peak = max(samples)
print(f"stream RSS baseline={baseline}KB end={end}KB peak={peak}KB")
if peak - baseline > 120_000 or end - baseline > 100_000:
    raise SystemExit('streaming playback RSS grew too quickly')
PY

kill -0 "$RUN_PID" 2>/dev/null || { echo "WallpaperMac exited before streaming memory test completed" >&2; exit 1; }
echo 'VIDEO_STREAM_MEMORY_REGRESSION_PASSED'
