#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXEC="$ROOT/dist/WallpaperMac.app/Contents/MacOS/WallpaperMac"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wallpapermac-external-navigation.XXXXXX")"
LIBRARY="$TEST_ROOT/Library"
DEFAULTS_BACKUP="$TEST_ROOT/defaults.plist"
DEFAULTS_BACKED_UP=0
RUN_PID=""
SERVER_PID=""
HIDDEN_PROCESS_NAMES=""

cleanup() {
    if [[ -n "$RUN_PID" ]] && kill -0 "$RUN_PID" 2>/dev/null; then
        kill "$RUN_PID" 2>/dev/null || true
        for _ in {1..20}; do
            kill -0 "$RUN_PID" 2>/dev/null || break
            sleep 0.2
        done
        kill -9 "$RUN_PID" 2>/dev/null || true
    fi
    [[ -z "$SERVER_PID" ]] || kill "$SERVER_PID" 2>/dev/null || true
    if [[ -n "$HIDDEN_PROCESS_NAMES" ]]; then
        for process_name in ${(s:,:)HIDDEN_PROCESS_NAMES}; do
            process_name="${process_name## }"
            osascript -e "tell application \"System Events\" to set visible of process \"$process_name\" to true" >/dev/null 2>&1 || true
        done
    fi
    if (( DEFAULTS_BACKED_UP )); then
        defaults import com.wallpaper.mac "$DEFAULTS_BACKUP" >/dev/null 2>&1 || true
    else
        defaults delete com.wallpaper.mac 'WallpaperMac.libraryPath' >/dev/null 2>&1 || true
        defaults delete com.wallpaper.mac 'WallpaperMac.onboardingCompleted' >/dev/null 2>&1 || true
        defaults delete com.wallpaper.mac 'WallpaperMac.webWallpaperInteractionEnabled' >/dev/null 2>&1 || true
    fi
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT INT TERM

cd "$ROOT"
test -x "$EXEC"
defaults export com.wallpaper.mac "$DEFAULTS_BACKUP" >/dev/null 2>&1 && DEFAULTS_BACKED_UP=1
mkdir -p "$LIBRARY/Assets"

# The local server exists only to detect an external browser opening the URL.
cat > "$TEST_ROOT/server.py" <<'PY'
import http.server, sys
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(sys.argv[2], 'a') as f:
            f.write(self.path + '\n')
        self.send_response(204)
        self.end_headers()
    def log_message(self, *args):
        pass
server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
with open(sys.argv[1], 'w') as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
PY
python3 -I "$TEST_ROOT/server.py" "$TEST_ROOT/port" "$TEST_ROOT/requests" &
SERVER_PID=$!
for _ in {1..40}; do
    [[ -f "$TEST_ROOT/port" ]] && break
    sleep 0.1
done
PORT="$(cat "$TEST_ROOT/port")"

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

SITE="$TEST_ROOT/site"
mkdir -p "$SITE"
cat > "$SITE/index.html" <<HTML
<!doctype html>
<html><body><a id="auto" style="position:absolute;left:200px;top:200px" href="http://127.0.0.1:$PORT/automatic" target="_blank">automatic</a>
<a id="other" style="position:absolute;left:400px;top:200px" href="http://127.0.0.1:$PORT/other" target="_blank">other</a>
<script>
for (const delay of [100, 250, 400]) {
  setTimeout(() => document.getElementById('auto').click(), delay);
}
</script></body></html>
HTML

python3 - "$LIBRARY" "$SITE" "display-$DISPLAY_NUMBER" "$DISPLAY_NAME" <<'PY'
import json, sys, uuid
from datetime import datetime, timezone
from pathlib import Path
library = Path(sys.argv[1])
site = Path(sys.argv[2])
now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z')
item_id = str(uuid.uuid4()).upper()
item = {
    'id': item_id, 'name': 'Automatic navigation fixture', 'type': 'web',
    'sourceURL': site.as_uri(), 'entryURL': (site / 'index.html').as_uri(),
    'storageMode': 'externalReference', 'availability': 'available',
    'createdAt': now, 'isFavorite': False,
}
(library / 'wallpapers.json').write_text(json.dumps([item], separators=(',', ':')))
(library / 'display-assignments.json').write_text(json.dumps([{
    'id': sys.argv[3], 'displayName': sys.argv[4], 'isConnected': True,
    'wallpaperID': item_id, 'applicationState': 'applied',
}], separators=(',', ':')))
PY

defaults write com.wallpaper.mac 'WallpaperMac.libraryPath' -string "$LIBRARY"
defaults write com.wallpaper.mac 'WallpaperMac.onboardingCompleted' -bool YES
defaults write com.wallpaper.mac 'WallpaperMac.webWallpaperInteractionEnabled' -bool YES
env WALLPAPERMAC_EXTERNAL_OPEN_LOG="$TEST_ROOT/opener.log" "$EXEC" >"$TEST_ROOT/app.log" 2>&1 &
RUN_PID=$!
sleep 4
kill -0 "$RUN_PID" 2>/dev/null || { echo 'WallpaperMac exited during external-navigation test' >&2; cat "$TEST_ROOT/app.log" >&2; exit 1; }
REQUEST_COUNT=0
[[ ! -f "$TEST_ROOT/requests" ]] || REQUEST_COUNT="$(wc -l < "$TEST_ROOT/requests" | tr -d ' ')"
printf 'automatic external requests: %s\n' "$REQUEST_COUNT"
[[ "$REQUEST_COUNT" -eq 0 ]] || { echo 'script-generated navigation opened an external browser' >&2; exit 1; }

# Positive control: one real mouse click must invoke the recording opener once.
osascript -e 'tell application "System Events" to tell process "WallpaperMac" to click button 1 of window 1' >/dev/null 2>&1 || true
HIDDEN_PROCESS_NAMES="$(osascript -e 'tell application "System Events" to get name of every process whose visible is true and name is not "WallpaperMac"' 2>/dev/null || true)"
if [[ -n "$HIDDEN_PROCESS_NAMES" ]]; then
    osascript -e 'tell application "System Events" to set visible of every process whose visible is true and name is not "WallpaperMac" to false' >/dev/null 2>&1 || true
fi
sleep 1
cat > "$TEST_ROOT/window-bounds.swift" <<'SWIFT'
import CoreGraphics
let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
for item in windows {
    guard let owner = item[kCGWindowOwnerName as String] as? String, owner == "WallpaperMac",
          let layer = item[kCGWindowLayer as String] as? Int, layer < 0,
          let bounds = item[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? CGFloat, width > 100,
          let height = bounds["Height"] as? CGFloat, height > 100 else { continue }
    print("\(bounds["X"] ?? 0)\t\(bounds["Y"] ?? 0)")
    break
}
SWIFT
/usr/bin/swiftc "$TEST_ROOT/window-bounds.swift" -o "$TEST_ROOT/window-bounds" -framework CoreGraphics >/dev/null
BOUNDS="$("$TEST_ROOT/window-bounds")"
ORIGIN_X="$(print -r -- "$BOUNDS" | awk -F '\t' '{print $1}')"
ORIGIN_Y="$(print -r -- "$BOUNDS" | awk -F '\t' '{print $2}')"
[[ -n "$ORIGIN_X" && -n "$ORIGIN_Y" ]] || { echo 'no interactive wallpaper window found' >&2; exit 1; }
cat > "$TEST_ROOT/click.swift" <<'SWIFT'
import CoreGraphics
let x = Double(CommandLine.arguments[1])! + 210
let y = Double(CommandLine.arguments[2])! + 215
let point = CGPoint(x: x, y: y)
let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
down?.post(tap: .cghidEventTap)
up?.post(tap: .cghidEventTap)
SWIFT
/usr/bin/swiftc "$TEST_ROOT/click.swift" -o "$TEST_ROOT/click" -framework CoreGraphics >/dev/null
"$TEST_ROOT/click" "$ORIGIN_X" "$ORIGIN_Y"
sleep 2
OPEN_COUNT=0
[[ ! -f "$TEST_ROOT/opener.log" ]] || OPEN_COUNT="$(wc -l < "$TEST_ROOT/opener.log" | tr -d ' ')"
printf 'native click opener calls: %s\n' "$OPEN_COUNT"
[[ "$OPEN_COUNT" -eq 1 ]] || { echo 'one native click should open exactly once' >&2; cat "$TEST_ROOT/app.log" >&2; exit 1; }

# Cross-target drag must not activate B or leave an external-navigation grant.
cat > "$TEST_ROOT/drag.swift" <<'SWIFT'
import CoreGraphics
import Foundation
let x = Double(CommandLine.arguments[1])!
let y = Double(CommandLine.arguments[2])!
let small = CommandLine.arguments.count > 3 && CommandLine.arguments[3] == "small"
let downPoint = CGPoint(x: x + 210, y: y + 215)
let upPoint = CGPoint(x: downPoint.x + (small ? 1 : 200), y: downPoint.y + (small ? 1 : 0))
let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: downPoint, mouseButton: .left)
let drag = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: upPoint, mouseButton: .left)
let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: upPoint, mouseButton: .left)
down?.post(tap: .cghidEventTap)
Thread.sleep(forTimeInterval: 0.05)
drag?.post(tap: .cghidEventTap)
Thread.sleep(forTimeInterval: 0.05)
up?.post(tap: .cghidEventTap)
SWIFT
/usr/bin/swiftc "$TEST_ROOT/drag.swift" -o "$TEST_ROOT/drag" -framework CoreGraphics >/dev/null
"$TEST_ROOT/drag" "$ORIGIN_X" "$ORIGIN_Y"
sleep 1
AFTER_DRAG=0
[[ ! -f "$TEST_ROOT/opener.log" ]] || AFTER_DRAG="$(wc -l < "$TEST_ROOT/opener.log" | tr -d ' ')"
[[ "$AFTER_DRAG" -eq 1 ]] || { echo 'cross-target drag activated another link' >&2; exit 1; }
printf 'cross_target_drag_opener_calls=%s\n' "$AFTER_DRAG"

# A one-pixel native drag is still a click; the six-pixel tolerance must remain
# effective rather than being canceled by the first mouseDragged event.
"$TEST_ROOT/drag" "$ORIGIN_X" "$ORIGIN_Y" small
sleep 1
AFTER_SMALL_DRAG="$(wc -l < "$TEST_ROOT/opener.log" | tr -d ' ')"
[[ "$AFTER_SMALL_DRAG" -eq 2 ]] || { echo 'small native drag should activate the same target once' >&2; cat "$TEST_ROOT/app.log" >&2; exit 1; }
printf 'small_drag_opener_calls=%s\n' "$AFTER_SMALL_DRAG"
if [[ -n "$HIDDEN_PROCESS_NAMES" ]]; then
    for process_name in ${(s:,:)HIDDEN_PROCESS_NAMES}; do
        process_name="${process_name## }"
        osascript -e "tell application \"System Events\" to set visible of process \"$process_name\" to true" >/dev/null 2>&1 || true
    done
fi
echo 'WEB_EXTERNAL_NAVIGATION_TEST_PASSED'
