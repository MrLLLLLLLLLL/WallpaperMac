#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/WallpaperMac.app"
EXEC="$APP/Contents/MacOS/WallpaperMac"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wallpapermac-web-interaction.XXXXXX")"
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

test -x "$EXEC"
pkill -x WallpaperMac >/dev/null 2>&1 || true
sleep 0.5
defaults export com.wallpaper.mac "$DEFAULTS_BACKUP" >/dev/null 2>&1 && DEFAULTS_BACKED_UP=1
mkdir -p "$LIBRARY/Assets" "$TEST_ROOT/site"

cat > "$TEST_ROOT/site/index.html" <<'HTML'
<!doctype html>
<html lang="zh-CN">
<meta charset="utf-8">
<title>WallpaperMac Click Test</title>
<style>
html,body{margin:0;width:100%;height:100%;background:#111;color:white;font:32px -apple-system}
body{display:grid;place-items:center}
button{width:320px;height:160px;font-size:36px;background:#333;color:white;border:2px solid #777;border-radius:18px}
</style>
<body onmousedown="document.body.style.backgroundColor='#00ff00'; window.webkit.messageHandlers.wallpaperMac.postMessage('clicked')">
<button>点击测试</button>
</body>
</html>
HTML

cat > "$TEST_ROOT/list-wallpaper-windows.swift" <<'SWIFT'
import CoreGraphics
let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
for item in windows {
    guard let owner = item[kCGWindowOwnerName as String] as? String, owner == "WallpaperMac" else { continue }
    let layer = item[kCGWindowLayer as String] as? Int ?? -1
    let windowID = item[kCGWindowNumber as String] as? Int ?? -1
    let bounds = item[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let iconLayer = CGWindowLevelForKey(.desktopIconWindow)
    let width = bounds["Width"] as? CGFloat ?? 0
    let height = bounds["Height"] as? CGFloat ?? 0
    guard layer < 0, width > 100, height > 100 else { continue }
    print("windowID=\(windowID) layer=\(layer) iconLayer=\(iconLayer) X=\(bounds["X"] ?? 0) Y=\(bounds["Y"] ?? 0) W=\(width) H=\(height)")
}
SWIFT
/usr/bin/swiftc "$TEST_ROOT/list-wallpaper-windows.swift" -o "$TEST_ROOT/list-wallpaper-windows" -framework CoreGraphics >/dev/null



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

python3 - "$LIBRARY" "$TEST_ROOT/site" "$DISPLAY_NUMBER" "$DISPLAY_NAME" <<'PY'
import json, sys, uuid
from datetime import datetime, timezone
from pathlib import Path
library, site, display_number, display_name = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4]
now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace('+00', 'Z')
item = {
    'id': str(uuid.uuid4()).upper(),
    'name': 'Web Click Fixture',
    'type': 'web',
    'sourceURL': site.as_uri(),
    'entryURL': (site / 'index.html').as_uri(),
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
defaults write com.wallpaper.mac 'WallpaperMac.webWallpaperInteractionEnabled' -bool YES
env | grep "^WALLPAPERMAC_" > "$TEST_ROOT/launch-env.txt" || true
"$EXEC" >"$TEST_ROOT/app.log" 2>&1 &
RUN_PID=$!

WINDOW_INFO=""
for _ in {1..40}; do
    WINDOW_INFO="$("$TEST_ROOT/list-wallpaper-windows" | awk '/windowID=/ { print; exit }')"
    [[ -n "$WINDOW_INFO" ]] && break
    sleep 0.25
done
[[ -n "$WINDOW_INFO" ]] || { echo "no wallpaper window for web interaction test" >&2; cat "$TEST_ROOT/app.log" >&2; exit 1; }

WINDOW_ID="$(print -r -- "$WINDOW_INFO" | awk '{sub("windowID=", "", $1); print $1}')"
WINDOW_LAYER="$(print -r -- "$WINDOW_INFO" | awk '{sub("layer=", "", $2); print $2}')"
ICON_LAYER="$(print -r -- "$WINDOW_INFO" | awk '{sub("iconLayer=", "", $3); print $3}')"
# The click-effect option must put the web wallpaper above the desktop icon
# layer; the wallpaper window itself remains owned by WallpaperMac.
if (( WINDOW_LAYER <= ICON_LAYER )); then
    echo "web wallpaper window is not above the desktop icon layer" >&2
    exit 1
fi

echo 'WEB_WALLPAPER_INTERACTION_TEST_PASSED'
