#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/WallpaperMac.app"
EXEC="$APP/Contents/MacOS/WallpaperMac"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wallpapermac-codec-test.XXXXXX")"
LIBRARY="$TEST_ROOT/Library"
SOURCE="${WALLPAPERMAC_TEST_SOURCE:-$TEST_ROOT/av1-source.mp4}"
LEGACY_CACHE="$TEST_ROOT/LegacyVideoPlaybackCache"
SOURCE_HASH_BEFORE="$TEST_ROOT/source-before.sha256"
SOURCE_HASH_AFTER="$TEST_ROOT/source-after.sha256"
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
FFPROBE="${WALLPAPERMAC_FFPROBE:-/opt/homebrew/bin/ffprobe}"
BUNDLED_FFMPEG="$APP/Contents/Resources/ffmpeg"
[[ -x "$FFMPEG" ]] || { echo "ffmpeg not found: $FFMPEG" >&2; exit 1; }
[[ -x "$BUNDLED_FFMPEG" ]] || { echo "bundled ffmpeg not found: $BUNDLED_FFMPEG" >&2; exit 1; }
"$BUNDLED_FFMPEG" -version | head -1
[[ -x "$FFPROBE" ]] || { echo "ffprobe not found: $FFPROBE" >&2; exit 1; }
test -x "$EXEC"

defaults export com.wallpaper.mac "$DEFAULTS_BACKUP" >/dev/null 2>&1 && DEFAULTS_BACKED_UP=1
mkdir -p "$LIBRARY/Assets" "$LEGACY_CACHE"
printf legacy > "$LEGACY_CACHE/legacy-compatible.mp4"

if [[ -n "${WALLPAPERMAC_TEST_SOURCE:-}" ]]; then
    echo '== Use supplied AV1 compatibility fixture =='
    test -r "$SOURCE"
else
    echo '== Build AV1 compatibility fixture =='
    "$FFMPEG" -hide_banner -loglevel error -y \
        -f lavfi -i 'testsrc2=size=640x360:rate=30' \
        -t 2 -c:v libsvtav1 -pix_fmt yuv420p "$SOURCE"
fi
shasum -a 256 "$SOURCE" > "$SOURCE_HASH_BEFORE"

python3 - "$TEST_ROOT" "$LIBRARY" "$SOURCE" <<'PY'
import json, sys, uuid
from datetime import datetime, timezone
from pathlib import Path
root = Path(sys.argv[1])
library = Path(sys.argv[2])
source = Path(sys.argv[3])
now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace('+00', 'Z')
item = {
    'id': str(uuid.uuid4()).upper(),
    'name': 'AV1 Compatibility Fixture',
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
ITEM_ID="$(python3 - "$LIBRARY/wallpapers.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))[0]['id'])
PY
)"
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

defaults write com.wallpaper.mac 'WallpaperMac.libraryPath' -string "$LIBRARY"
defaults write com.wallpaper.mac 'WallpaperMac.onboardingCompleted' -bool YES

echo '== Exercise AV1 streaming and external-reference storage =='
env WALLPAPERMAC_CACHE_DIR="$LEGACY_CACHE" WALLPAPERMAC_FFMPEG="$BUNDLED_FFMPEG" "$EXEC" >"$TEST_ROOT/app.log" 2>&1 &
RUN_PID=$!

cat > "$TEST_ROOT/list-wallpaper-windows.swift" <<'SWIFT'
import CoreGraphics
let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
for item in windows {
    guard let owner = item[kCGWindowOwnerName as String] as? String, owner == "WallpaperMac" else { continue }
    let layer = item[kCGWindowLayer as String] as? Int ?? -1
    let windowID = item[kCGWindowNumber as String] as? Int ?? -1
    print("windowID=\(windowID) layer=\(layer)")
}
SWIFT
/usr/bin/swiftc "$TEST_ROOT/list-wallpaper-windows.swift" -o "$TEST_ROOT/list-wallpaper-windows" -framework CoreGraphics >/dev/null

cat > "$TEST_ROOT/check-nonblack.swift" <<'SWIFT'
import AppKit
guard CommandLine.arguments.count == 2,
      let image = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("unable to load streaming wallpaper capture\n", stderr)
    exit(1)
}
let bitmap = NSBitmapImageRep(cgImage: cgImage)
var sampled = 0
var nonBlack = 0
for y in stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 80)) {
    for x in stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 80)) {
        guard let color = bitmap.colorAt(x: x, y: y) else { continue }
        sampled += 1
        if color.redComponent + color.greenComponent + color.blueComponent > 0.08 {
            nonBlack += 1
        }
    }
}
guard sampled > 0, Double(nonBlack) / Double(sampled) > 0.05 else {
    fputs("streaming wallpaper capture is effectively black: \(nonBlack)/\(sampled)\n", stderr)
    exit(1)
}
print("streamingNonBlack=\(nonBlack)/\(sampled)")
SWIFT
/usr/bin/swiftc "$TEST_ROOT/check-nonblack.swift" -o "$TEST_ROOT/check-nonblack" -framework AppKit >/dev/null

CAPTURE="$TEST_ROOT/av1-streaming-wallpaper.png"
VISIBLE=0
for _ in {1..80}; do
    kill -0 "$RUN_PID" 2>/dev/null || { echo "WallpaperMac exited during AV1 streaming" >&2; cat "$TEST_ROOT/app.log" >&2; exit 1; }
    WINDOW_ID="$("$TEST_ROOT/list-wallpaper-windows" | awk '/layer=-2147483623/ { sub("windowID=", "", $1); print $1; exit }')"
    if [[ -n "$WINDOW_ID" ]]; then
        /usr/sbin/screencapture -x -o -l "$WINDOW_ID" "$CAPTURE"
        if "$TEST_ROOT/check-nonblack" "$CAPTURE"; then
            VISIBLE=1
            break
        fi
    fi
    sleep 0.25
done
(( VISIBLE == 1 )) || { echo "AV1 streaming wallpaper did not become visible" >&2; cat "$TEST_ROOT/app.log" >&2; exit 1; }

if find "$TEST_ROOT" -type f -name '*-compatible.mp4' -print -quit | grep -q .; then
    echo "streaming playback created a full compatibility file" >&2
    find "$TEST_ROOT" -type f -name '*-compatible.mp4' -print >&2
    exit 1
fi
[[ ! -d "$LIBRARY/VideoProxies" ]] || { echo "external reference created VideoProxies" >&2; exit 1; }
[[ ! -e "$LEGACY_CACHE/legacy-compatible.mp4" ]] || { echo "legacy full playback cache was not removed" >&2; exit 1; }
shasum -a 256 "$SOURCE" > "$SOURCE_HASH_AFTER"
cmp -s "$SOURCE_HASH_BEFORE" "$SOURCE_HASH_AFTER" || { echo "external source changed during streaming" >&2; exit 1; }
kill -0 "$RUN_PID" 2>/dev/null || { echo "WallpaperMac exited after streaming" >&2; cat "$TEST_ROOT/app.log" >&2; exit 1; }

echo "VIDEO_CODEC_RUNTIME_TEST_PASSED"
echo "full-playback-copy=absent"
