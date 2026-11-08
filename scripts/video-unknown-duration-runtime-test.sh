#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXEC="$ROOT/dist/WallpaperMac.app/Contents/MacOS/WallpaperMac"
FFMPEG="${WALLPAPERMAC_FFMPEG:-/opt/homebrew/bin/ffmpeg}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wallpapermac-unknown-duration.XXXXXX")"
LIBRARY="$TEST_ROOT/Library"
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

cd "$ROOT"
test -x "$EXEC"
test -x "$FFMPEG"
defaults export com.wallpaper.mac "$DEFAULTS_BACKUP" >/dev/null 2>&1 && DEFAULTS_BACKED_UP=1
mkdir -p "$LIBRARY/Assets"
"$FFMPEG" -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=640x360:rate=30' \
    -t 62 -c:v libx264 -pix_fmt yuv420p "$TEST_ROOT/first.mp4"
"$FFMPEG" -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=640x360:rate=30' \
    -t 120 -c:v libx264 -pix_fmt yuv420p "$TEST_ROOT/second.mp4"

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

python3 - "$TEST_ROOT" "$LIBRARY" "display-$DISPLAY_NUMBER" "$DISPLAY_NAME" <<'PY'
import json, sys, uuid
from datetime import datetime, timezone
from pathlib import Path
root = Path(sys.argv[1])
library = Path(sys.argv[2])
now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z')
items = []
for name in ('first', 'second'):
    source = root / f'{name}.mp4'
    items.append({
        'id': str(uuid.uuid4()).upper(), 'name': name, 'type': 'video',
        'sourceURL': source.as_uri(), 'storageMode': 'externalReference',
        'availability': 'available', 'createdAt': now, 'isFavorite': False,
        # Deliberately no metadata: native AVPlayer must discover the duration.
    })
queue_id = str(uuid.uuid4()).upper()
(library / 'wallpapers.json').write_text(json.dumps(items, separators=(',', ':')))
(library / 'playback-queues.json').write_text(json.dumps([{
    'id': queue_id, 'name': 'Unknown duration regression', 'isDefault': True,
    'wallpaperIDs': [item['id'] for item in items], 'sortMode': 'custom',
    'playbackMode': 'sequential', 'completionBehavior': 'loop',
    'advanceMode': 'videoCompletion', 'advanceAfterVideoCompletion': True,
    'defaultIntervalSeconds': 30, 'transition': 'cut', 'itemIntervalOverrides': [],
    'createdAt': now, 'updatedAt': now,
}], separators=(',', ':')))
(library / 'display-assignments.json').write_text('[]')
(library / 'display-playback-bindings.json').write_text(json.dumps([{
    'displayID': sys.argv[3], 'displayName': sys.argv[4], 'activeQueueID': queue_id,
    'queueStates': [queue_id, {
        'queueID': queue_id, 'currentIndex': 0,
        'isPlaying': True, 'isEnabled': True, 'overrides': {},
    }],
}], separators=(',', ':')))
PY

defaults write com.wallpaper.mac 'WallpaperMac.libraryPath' -string "$LIBRARY"
defaults write com.wallpaper.mac 'WallpaperMac.onboardingCompleted' -bool YES
"$EXEC" >"$TEST_ROOT/app.log" 2>&1 &
RUN_PID=$!

current_index() {
    python3 - "$LIBRARY/display-playback-bindings.json" <<'PY'
import json, sys
binding = json.load(open(sys.argv[1]))[0]
print(binding['queueStates'][1].get('currentIndex', -1))
PY
}

# At 55 seconds the first 62-second video must still be playing. In particular,
# the old unknown-duration watchdog would already be approaching a false stall.
sleep 55
INDEX_AT_55="$(current_index)"
[[ "$INDEX_AT_55" -eq 0 ]] || { echo 'unknown-duration video advanced before completion' >&2; exit 1; }
# The actual completion must still work after the former 60-second stall window.
sleep 10
INDEX_AT_65="$(current_index)"
[[ "$INDEX_AT_65" -eq 1 ]] || { echo 'video did not advance at its real completion' >&2; cat "$TEST_ROOT/app.log" >&2; exit 1; }
printf 'unknown_duration_index_at_55=%s at_65=%s\n' "$INDEX_AT_55" "$INDEX_AT_65"
echo 'VIDEO_UNKNOWN_DURATION_RUNTIME_TEST_PASSED'
