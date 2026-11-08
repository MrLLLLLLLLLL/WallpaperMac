#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXEC="$ROOT/dist/WallpaperMac.app/Contents/MacOS/WallpaperMac"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wallpapermac-hidden-test.XXXXXX")"
DEFAULTS_BACKUP="$TEST_ROOT/defaults.plist"
DEFAULTS_BACKED_UP=0
CONFIG_DIR="$HOME/Library/Application Support/WallpaperMac/Configuration"
CONFIG_BACKUP="$TEST_ROOT/configuration-backup"
CONFIG_EXISTED=0
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
    for key in 'WallpaperMac.libraryPath' 'WallpaperMac.onboardingCompleted' 'WallpaperMac.fitMode'; do
        defaults delete com.wallpaper.mac "$key" >/dev/null 2>&1 || true
    done
    if (( DEFAULTS_BACKED_UP )); then
        defaults import com.wallpaper.mac "$DEFAULTS_BACKUP" >/dev/null 2>&1 || true
    fi
    if (( CONFIG_EXISTED )); then
        rm -rf "$CONFIG_DIR"
        cp -R "$CONFIG_BACKUP" "$CONFIG_DIR"
    else
        rm -f "$CONFIG_DIR/library-configuration.json"
    fi
    if [[ "${WALLPAPERMAC_TEST_KEEP_ARTIFACTS:-0}" == 1 ]]; then
        printf 'hidden test artifacts: %s\n' "$TEST_ROOT"
    else
        rm -rf "$TEST_ROOT"
    fi
}
trap cleanup EXIT INT TERM

cd "$ROOT"
test -x "$EXEC"
if pgrep -x WallpaperMac >/dev/null 2>&1; then
    echo 'quit any running WallpaperMac instance before the hidden wallpaper test' >&2
    exit 1
fi
defaults export com.wallpaper.mac "$DEFAULTS_BACKUP" >/dev/null 2>&1 && DEFAULTS_BACKED_UP=1
if [[ -d "$CONFIG_DIR" ]]; then cp -R "$CONFIG_DIR" "$CONFIG_BACKUP"; CONFIG_EXISTED=1; fi
mkdir -p "$TEST_ROOT/Library/Assets" "$TEST_ROOT/Library/Thumbnails"

python3 - "$TEST_ROOT" <<'PY'
import struct, sys, zlib
from pathlib import Path
root = Path(sys.argv[1])
def write_png(path, color):
    w, h = 32, 16
    rows = []
    for _ in range(h):
        rows.append(b'\x00' + bytes(color) * w)
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    png = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(b''.join(rows)))
    png += chunk(b'IEND', b'')
    path.write_bytes(png)
write_png(root / 'visible.png', (220, 35, 35))
write_png(root / 'hidden.png', (35, 210, 70))
PY

cat > "$TEST_ROOT/list-screens.swift" <<'SWIFT'
import AppKit
for screen in NSScreen.screens {
    let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    print("\(number?.uint32Value ?? 0)\t\(screen.localizedName)")
}
SWIFT
/usr/bin/swiftc "$TEST_ROOT/list-screens.swift" -o "$TEST_ROOT/list-screens" -framework AppKit >/dev/null
SCREEN_INFO="$("$TEST_ROOT/list-screens" | head -1)"
DISPLAY_NUMBER="$(print -r -- "$SCREEN_INFO" | awk -F '\t' '{print $1}')"
DISPLAY_NAME="$(print -r -- "$SCREEN_INFO" | awk -F '\t' '{print $2}')"

cat > "$TEST_ROOT/list-wallpaper-windows.swift" <<'SWIFT'
import CoreGraphics
let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
for item in windows {
    guard let owner = item[kCGWindowOwnerName as String] as? String, owner == "WallpaperMac",
          let layer = item[kCGWindowLayer as String] as? Int, layer < 0,
          let bounds = item[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? CGFloat, width > 100,
          let height = bounds["Height"] as? CGFloat, height > 100 else { continue }
    print("\(item[kCGWindowNumber as String] ?? -1)\t\(bounds["Width"] ?? 0)\t\(bounds["Height"] ?? 0)")
    break
}
SWIFT
/usr/bin/swiftc "$TEST_ROOT/list-wallpaper-windows.swift" -o "$TEST_ROOT/list-wallpaper-windows" -framework CoreGraphics >/dev/null

cat > "$TEST_ROOT/check-red.swift" <<'SWIFT'
import AppKit
guard let image = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("cannot read capture\n", stderr); exit(1)
}
let bitmap = NSBitmapImageRep(cgImage: cg)
guard let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2) else {
    fputs("cannot sample capture\n", stderr); exit(1)
}
guard color.redComponent > 0.65 && color.greenComponent < 0.35 && color.blueComponent < 0.35 else {
    fputs("visible wallpaper was not shown: \(color)\n", stderr); exit(1)
}
print("locked queue skipped the hidden wallpaper")
SWIFT
/usr/bin/swiftc "$TEST_ROOT/check-red.swift" -o "$TEST_ROOT/check-red" -framework AppKit >/dev/null

write_library() {
    local library="$1"
    local hidden_flag="$2"
    rm -rf "$library"
    mkdir -p "$library/Assets" "$library/Thumbnails"
    python3 - "$library" "$TEST_ROOT" "$DISPLAY_NUMBER" "$DISPLAY_NAME" "$hidden_flag" <<'PY'
import json, sys, uuid
from datetime import datetime, timezone
from pathlib import Path
library = Path(sys.argv[1]); root = Path(sys.argv[2])
display_id = f"display-{sys.argv[3]}"
display_name = sys.argv[4]
hidden_flag = sys.argv[5] == "all-hidden"
now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z')
visible_id = str(uuid.uuid4()).upper()
hidden_id = str(uuid.uuid4()).upper()
queue_id = "50197D0A-990D-4741-B007-AC97D4B778D1"
def item(item_id, name, path, hidden):
    return {
        "id": item_id, "name": name, "type": "image",
        "sourceURL": (root / path).as_uri(), "storageMode": "externalReference",
        "availability": "available", "createdAt": now, "isFavorite": False,
        "isHidden": hidden
    }
items = [
    item(visible_id, "visible", "visible.png", hidden_flag),
    item(hidden_id, "hidden", "hidden.png", True)
]
(library / "wallpapers.json").write_text(json.dumps(items, separators=(',', ':')))
queue = {
    "id": queue_id, "name": "默认队列", "isDefault": True,
    "wallpaperIDs": [hidden_id, visible_id],
    "playbackMode": "sequential", "completionBehavior": "loop",
    "advanceMode": "fixedInterval", "sortMode": "custom",
    "defaultIntervalSeconds": 30, "transition": "cut",
    "itemIntervalOverrides": [], "advanceAfterVideoCompletion": False,
    "createdAt": now, "updatedAt": now
}
(library / "playback-queues.json").write_text(json.dumps([queue], separators=(',', ':')))
state = {
    "queueID": queue_id, "currentIndex": 0, "isPlaying": True,
    "isEnabled": True, "overrides": {}
}
binding = {
    "displayID": display_id, "displayName": display_name,
    "activeQueueID": queue_id, "queueStates": [queue_id, state]
}
(library / "display-playback-bindings.json").write_text(json.dumps([binding], separators=(',', ':')))
(library / "display-assignments.json").write_text("[]")
PY
}

run_app() {
    defaults write com.wallpaper.mac 'WallpaperMac.libraryPath' -string "$1"
    sleep 0.5
    "$EXEC" >"$TEST_ROOT/app.log" 2>&1 &
    RUN_PID=$!
    sleep 2
}

stop_app() {
    kill "$RUN_PID" 2>/dev/null || true
    for _ in {1..30}; do kill -0 "$RUN_PID" 2>/dev/null || break; sleep 0.2; done
    kill -9 "$RUN_PID" 2>/dev/null || true
    wait "$RUN_PID" 2>/dev/null || true
    RUN_PID=""
    # Give the window server a moment to retire the old process's windows.
    sleep 1
}

write_library "$TEST_ROOT/Library-mixed" mixed
defaults write com.wallpaper.mac 'WallpaperMac.onboardingCompleted' -bool YES
defaults write com.wallpaper.mac 'WallpaperMac.fitMode' -string fill
run_app "$TEST_ROOT/Library-mixed"
WINDOW_INFO=""
for _ in {1..40}; do
    WINDOW_INFO="$("$TEST_ROOT/list-wallpaper-windows")"
    [[ -n "$WINDOW_INFO" ]] && break
    sleep 0.25
done
[[ -n "$WINDOW_INFO" ]] || { echo 'no wallpaper window for the visible queue item' >&2; cat "$TEST_ROOT/app.log" >&2; exit 1; }
WINDOW_ID="$(print -r -- "$WINDOW_INFO" | awk -F '\t' '{print $1}')"
/usr/sbin/screencapture -x -o -l "$WINDOW_ID" "$TEST_ROOT/mixed.png"
"$TEST_ROOT/check-red" "$TEST_ROOT/mixed.png"
stop_app

write_library "$TEST_ROOT/Library-all-hidden" all-hidden
run_app "$TEST_ROOT/Library-all-hidden"
sleep 4
if [[ -n "$("$TEST_ROOT/list-wallpaper-windows")" ]]; then
    echo 'a hidden-only queue must not create a wallpaper window' >&2
    echo '--- wallpaper windows ---' >&2
    "$TEST_ROOT/list-wallpaper-windows" >&2
    echo '--- processes ---' >&2
    pgrep -x WallpaperMac >&2 || true
    echo '--- default library ---' >&2
    defaults read com.wallpaper.mac 'WallpaperMac.libraryPath' >&2 || true
    echo '--- fixture wallpapers ---' >&2
    python3 -I - "$TEST_ROOT/Library-all-hidden" <<'PY' >&2
import json, sys
from pathlib import Path
lib = Path(sys.argv[1])
for item in json.loads((lib / "wallpapers.json").read_text()):
    print(item["name"], "isHidden=", item.get("isHidden"))
PY
    echo '--- fixture profiles ---' >&2
    test -f "$TEST_ROOT/Library-all-hidden/display-profiles.json" && cat "$TEST_ROOT/Library-all-hidden/display-profiles.json" >&2 || true
    echo '--- app log ---' >&2
    cat "$TEST_ROOT/app.log" >&2 || true
    exit 1
fi
echo 'hidden-only queue did not display a wallpaper'
stop_app

echo 'HIDDEN_WALLPAPERS_RUNTIME_TEST_PASSED'
