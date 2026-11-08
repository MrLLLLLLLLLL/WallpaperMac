#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXEC="$ROOT/dist/WallpaperMac.app/Contents/MacOS/WallpaperMac"
FFMPEG="${WALLPAPERMAC_FFMPEG:-/opt/homebrew/bin/ffmpeg}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wallpapermac-stream-failure.XXXXXX")"
LIBRARY="$TEST_ROOT/Library"
SOURCE="$TEST_ROOT/av1-source.mp4"
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

"$FFMPEG" -hide_banner -loglevel error -y \
    -f lavfi -i 'testsrc2=size=640x360:rate=30' \
    -t 2 -c:v libsvtav1 -pix_fmt yuv420p "$SOURCE"

python3 - "$LIBRARY" "$SOURCE" <<'PY'
import json, sys, uuid
from datetime import datetime, timezone
from pathlib import Path
library = Path(sys.argv[1])
source = Path(sys.argv[2])
now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z')
item = {
    'id': str(uuid.uuid4()).upper(),
    'name': 'AV1 Failure Fixture',
    'type': 'video',
    'sourceURL': source.as_uri(),
    'storageMode': 'externalReference',
    'availability': 'available',
    'createdAt': now,
    'isFavorite': False,
}
(library / 'wallpapers.json').write_text(json.dumps([item], separators=(',', ':')))
(library / 'display-assignments.json').write_text('[]')
PY

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
ITEM_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[0]["id"])' "$LIBRARY/wallpapers.json")"
python3 - "$LIBRARY/display-assignments.json" "$DISPLAY_NUMBER" "$DISPLAY_NAME" "$ITEM_ID" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps([{
    'id': f'display-{sys.argv[2]}',
    'displayName': sys.argv[3],
    'isConnected': True,
    'wallpaperID': sys.argv[4],
    'applicationState': 'applied',
}], separators=(',', ':')))
PY

# A controllable decoder failure: every launch is logged and exits non-zero.
cat > "$TEST_ROOT/failing-ffmpeg" <<'SH'
#!/bin/zsh
printf '%s\n' "$$" >> "$WALLPAPERMAC_FFMPEG_TEST_COUNT"
exit 1
SH
chmod +x "$TEST_ROOT/failing-ffmpeg"
export WALLPAPERMAC_FFMPEG_TEST_COUNT="$TEST_ROOT/launch-count"
defaults write com.wallpaper.mac 'WallpaperMac.libraryPath' -string "$LIBRARY"
defaults write com.wallpaper.mac 'WallpaperMac.onboardingCompleted' -bool YES
defaults write com.wallpaper.mac 'WallpaperMac.loops' -bool YES

env WALLPAPERMAC_FFMPEG="$TEST_ROOT/failing-ffmpeg" "$EXEC" >"$TEST_ROOT/app.log" 2>&1 &
RUN_PID=$!
# Startup restoration and codec probing are asynchronous. Wait for the first
# actual launch, then require the count to settle instead of sampling a fixed
# wall-clock time that can precede initialization.
FIRST_LAUNCHES=0
for _ in {1..40}; do
    [[ ! -f "$WALLPAPERMAC_FFMPEG_TEST_COUNT" ]] || FIRST_LAUNCHES="$(wc -l < "$WALLPAPERMAC_FFMPEG_TEST_COUNT" | tr -d ' ')"
    [[ "$FIRST_LAUNCHES" -gt 0 ]] && break
    sleep 0.25
done
[[ "$FIRST_LAUNCHES" -gt 0 ]] || { echo 'decoder was never launched' >&2; cat "$TEST_ROOT/app.log" >&2; exit 1; }
sleep 3
kill -0 "$RUN_PID" 2>/dev/null || { echo 'WallpaperMac exited during decoder failure test' >&2; cat "$TEST_ROOT/app.log" >&2; exit 1; }
SECOND_LAUNCHES=0
[[ ! -f "$WALLPAPERMAC_FFMPEG_TEST_COUNT" ]] || SECOND_LAUNCHES="$(wc -l < "$WALLPAPERMAC_FFMPEG_TEST_COUNT" | tr -d ' ')"
printf 'failed decoder launches: startup=%s after_5_seconds=%s\n' "$FIRST_LAUNCHES" "$SECOND_LAUNCHES"
[[ "$FIRST_LAUNCHES" -le 2 && "$SECOND_LAUNCHES" -le 2 ]] || { echo 'decoder failure restarted without a bound' >&2; exit 1; }
[[ "$SECOND_LAUNCHES" -eq "$FIRST_LAUNCHES" ]] || { echo 'decoder failure continued restarting after startup' >&2; exit 1; }

echo 'VIDEO_STREAM_FAILURE_TEST_PASSED'
