#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/WallpaperMac.app"
EXEC="$APP/Contents/MacOS/WallpaperMac"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wallpapermac-queue-memory.XXXXXX")"
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
/usr/bin/codesign --verify --deep --strict "$APP"
defaults export com.wallpaper.mac "$DEFAULTS_BACKUP" >/dev/null 2>&1 && DEFAULTS_BACKED_UP=1
mkdir -p "$LIBRARY/Assets"

cat > "$TEST_ROOT/make-fixtures.py" <<'PY'
import json
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

library = Path(sys.argv[1])
now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z')
items = []
for index in range(3):
    root = library.parent / f"site-{index}"
    root.mkdir(parents=True, exist_ok=True)
    html = f'''<!doctype html>
<html><head><meta charset="utf-8"><title>Queue memory fixture {index}</title>
<style>html,body{{margin:0;width:100%;height:100%;background:rgb({20 + index * 30}, {25 + index * 20}, {45 + index * 25});color:white;font:48px -apple-system;display:grid;place-items:center}}</style></head>
<body>Queue fixture {index}<script>setInterval(() => document.body.style.opacity = document.body.style.opacity === '0.8' ? '1' : '0.8', 100);</script></body></html>'''
    entry = root / 'index.html'
    entry.write_text(html)
    item_id = str(uuid.uuid4()).upper()
    items.append({
        'id': item_id,
        'name': f'Queue fixture {index}',
        'type': 'web',
        'sourceURL': root.as_uri(),
        'entryURL': entry.as_uri(),
        'storageMode': 'externalReference',
        'availability': 'available',
        'createdAt': now,
        'isFavorite': False,
    })

queue_id = str(uuid.uuid4()).upper()
(library / 'wallpapers.json').write_text(json.dumps(items, separators=(',', ':')))
(library / 'playback-queues.json').write_text(json.dumps([{
    'id': queue_id,
    'name': 'Queue memory regression',
    'isDefault': True,
    'wallpaperIDs': [item['id'] for item in items],
    'sortMode': 'custom',
    'playbackMode': 'sequential',
    'completionBehavior': 'loop',
    'defaultIntervalSeconds': 1,
    'transition': 'cut',
    'itemIntervalOverrides': [],
    'createdAt': now,
    'updatedAt': now,
}], separators=(',', ':')))
(library / 'display-assignments.json').write_text('[]')
(library / 'display-playback-bindings.json').write_text(json.dumps([{
    'displayID': sys.argv[2],
    'displayName': sys.argv[3],
    'activeQueueID': queue_id,
    'queueStates': [queue_id, {
        'queueID': queue_id,
        'currentIndex': 0,
        'isPlaying': True,
        'isEnabled': True,
        'overrides': {},
    }],
}], separators=(',', ':')))
PY

cat > "$TEST_ROOT/list-screen.swift" <<'SWIFT'
import AppKit
for (index, screen) in NSScreen.screens.enumerated() {
    let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    print("\(index)\t\(number?.stringValue ?? String(index))\t\(screen.localizedName)")
}
SWIFT
swiftc "$TEST_ROOT/list-screen.swift" -o "$TEST_ROOT/list-screen" -framework AppKit >/dev/null
SCREEN_INFO="$("$TEST_ROOT/list-screen" | head -1)"
if [[ -z "$SCREEN_INFO" ]]; then
    echo 'ERROR: no display is available for queue memory regression.' >&2
    exit 1
fi
DISPLAY_NUMBER="$(print -r -- "$SCREEN_INFO" | awk -F '\t' '{print $2}')"
DISPLAY_NAME="$(print -r -- "$SCREEN_INFO" | awk -F '\t' '{print $3}')"
DISPLAY_ID="display-$DISPLAY_NUMBER"
python3 "$TEST_ROOT/make-fixtures.py" "$LIBRARY" "$DISPLAY_ID" "$DISPLAY_NAME"

cat > "$TEST_ROOT/list-wallpaper-windows.swift" <<'SWIFT'
import CoreGraphics
let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
let count = windows.reduce(into: 0) { count, item in
    let owner = item[kCGWindowOwnerName as String] as? String
    let layer = item[kCGWindowLayer as String] as? Int ?? 0
    let bounds = item[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let width = bounds["Width"] as? CGFloat ?? 0
    let height = bounds["Height"] as? CGFloat ?? 0
    if owner == "WallpaperMac" && layer < 0 && width > 100 && height > 100 { count += 1 }
}
print(count)
SWIFT
swiftc "$TEST_ROOT/list-wallpaper-windows.swift" -o "$TEST_ROOT/list-wallpaper-windows" -framework CoreGraphics >/dev/null

defaults write com.wallpaper.mac 'WallpaperMac.libraryPath' -string "$LIBRARY"
defaults write com.wallpaper.mac 'WallpaperMac.onboardingCompleted' -bool YES
pkill -x WallpaperMac 2>/dev/null || true
sleep 1
open -n "$APP"
for _ in {1..40}; do
    RUN_PID="$(pgrep -x WallpaperMac | head -1 || true)"
    [[ -n "$RUN_PID" ]] && break
    sleep 0.25
done
if [[ -z "$RUN_PID" ]]; then
    echo 'ERROR: WallpaperMac did not start.' >&2
    exit 1
fi

RSS_FILE="$TEST_ROOT/rss.tsv"
WINDOW_FILE="$TEST_ROOT/windows.tsv"
QUEUE_STATE_FILE="$TEST_ROOT/queue-state.tsv"
for second in {1..24}; do
    sleep 1
    rss="$(ps -o rss= -p "$RUN_PID" | tr -d ' ' || true)"
    [[ -z "$rss" ]] && { echo 'ERROR: WallpaperMac exited during queue memory regression.' >&2; exit 1; }
    windows="$($TEST_ROOT/list-wallpaper-windows)"
    current_index="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[0]["queueStates"][1].get("currentIndex", -1))' "$LIBRARY/display-playback-bindings.json" 2>/dev/null || print -r -- -1)"
    printf '%s\t%s\n' "$second" "$rss" >> "$RSS_FILE"
    printf '%s\t%s\n' "$second" "$windows" >> "$WINDOW_FILE"
    printf '%s\t%s\n' "$second" "$current_index" >> "$QUEUE_STATE_FILE"
done

python3 - "$RSS_FILE" "$WINDOW_FILE" "$QUEUE_STATE_FILE" <<'PY'
import json
import statistics
import sys
from pathlib import Path

rss_rows = [(int(a), int(b)) for a, b in (line.split('\t') for line in Path(sys.argv[1]).read_text().splitlines())]
window_rows = [(int(a), int(b)) for a, b in (line.split('\t') for line in Path(sys.argv[2]).read_text().splitlines())]
queue_states = [int(value) for _, value in (line.split('\t') for line in Path(sys.argv[3]).read_text().splitlines())]
if len({value for value in queue_states if value >= 0}) < 2:
    raise SystemExit(f'ERROR: queue currentIndex never advanced: {queue_states}')

# Ignore initial WebKit startup. A real leak produces a sustained increase after
# the warm-up window, not just a one-time process initialization allocation.
warm = [rss for second, rss in rss_rows if second >= 5 and second <= 8]
tail = [rss for second, rss in rss_rows if second >= 21]
base = statistics.median(warm)
end = statistics.median(tail)
peak = max(rss for second, rss in rss_rows if second >= 5)
if end - base > 16 * 1024 or peak - base > 32 * 1024:
    raise SystemExit(f'ERROR: RSS grew during queue playback: baseline={base}KB end={end}KB peak={peak}KB')

values = [value for _, value in window_rows]
# Wallpaper windows are created after the AppKit run loop starts. Do not treat
# the first startup sample as a leaked or missing window; evaluate the stable
# warm-up interval and the tail where queue transitions have occurred.
warm_windows = [value for second, value in window_rows if 5 <= second <= 8]
tail_windows = [value for second, value in window_rows if second >= 15]
window_baseline = statistics.median(warm_windows)
window_tail = statistics.median(tail_windows)
window_tail_max = max(tail_windows)
if min(warm_windows) < 1 or window_tail > window_baseline + 1 or window_tail_max > window_baseline + 2:
    raise SystemExit(f'ERROR: wallpaper window count grew: baseline={window_baseline} tail={window_tail} max={window_tail_max} observed={values}')
print(f'Queue transitions advanced; RSS baseline={int(base)}KB end={int(end)}KB peak={int(peak)}KB; wallpaperWindows baseline={int(window_baseline)} tail={int(window_tail)} max={window_tail_max}')
PY

echo 'QUEUE_MEMORY_REGRESSION_PASSED'
