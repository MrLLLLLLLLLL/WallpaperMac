#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXEC="$ROOT/dist/WallpaperMac.app/Contents/MacOS/WallpaperMac"
FFMPEG="${WALLPAPERMAC_FFMPEG:-/opt/homebrew/bin/ffmpeg}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wallpapermac-fit-test.XXXXXX")"
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
    # `defaults import` merges, so remove the keys this test writes first;
    # otherwise a key absent from the backup survives pointing at deleted
    # test fixtures.
    for key in 'WallpaperMac.libraryPath' 'WallpaperMac.onboardingCompleted' 'WallpaperMac.fitMode'; do
        defaults delete com.wallpaper.mac "$key" >/dev/null 2>&1 || true
    done
    if (( DEFAULTS_BACKED_UP )); then
        defaults import com.wallpaper.mac "$DEFAULTS_BACKUP" >/dev/null 2>&1 || true
    fi
    # The app records the test library in a configuration file that outlives
    # UserDefaults; restore it so the next normal launch uses the real library.
    if (( CONFIG_EXISTED )); then
        rm -rf "$CONFIG_DIR"
        cp -R "$CONFIG_BACKUP" "$CONFIG_DIR"
    else
        rm -f "$CONFIG_DIR/library-configuration.json"
    fi
    if [[ "${WALLPAPERMAC_TEST_KEEP_ARTIFACTS:-0}" == 1 ]]; then
        printf 'fit test artifacts: %s\n' "$TEST_ROOT"
    else
        rm -rf "$TEST_ROOT"
    fi
}
trap cleanup EXIT INT TERM

cd "$ROOT"
test -x "$EXEC"
test -x "$FFMPEG"
if pgrep -x WallpaperMac >/dev/null 2>&1; then
    echo 'quit any running WallpaperMac instance before the fit runtime test' >&2
    exit 1
fi
defaults export com.wallpaper.mac "$DEFAULTS_BACKUP" >/dev/null 2>&1 && DEFAULTS_BACKED_UP=1
if [[ -d "$CONFIG_DIR" ]]; then
    cp -R "$CONFIG_DIR" "$CONFIG_BACKUP"
    CONFIG_EXISTED=1
fi
mkdir -p "$TEST_ROOT/Library/Assets"

python3 - "$TEST_ROOT" <<'PY'
import struct, sys, zlib
from pathlib import Path
root = Path(sys.argv[1])
def write_pattern(path, w, h):
    rows=[]
    for y in range(h):
        row=bytearray()
        for x in range(w):
            if x < w/2 and y < h/2: color=(220, 35, 35)
            elif x >= w/2 and y < h/2: color=(35, 210, 70)
            elif x < w/2 and y >= h/2: color=(35, 80, 220)
            else: color=(220, 190, 35)
            row.extend(color)
        rows.append(b'\x00' + bytes(row))
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    png = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(b''.join(rows)))
    png += chunk(b'IEND', b'')
    path.write_bytes(png)
write_pattern(root / 'tile.png', 32, 16)
write_pattern(root / 'landscape-16x9.png', 128, 72)
PY
"$FFMPEG" -hide_banner -loglevel error -y -loop 1 -i "$TEST_ROOT/tile.png" \
    -t 3 -c:v libx264 -pix_fmt yuv420p "$TEST_ROOT/tile-h264.mp4"
"$FFMPEG" -hide_banner -loglevel error -y -loop 1 -i "$TEST_ROOT/tile.png" \
    -t 3 -c:v libsvtav1 -pix_fmt yuv420p "$TEST_ROOT/tile-av1.mp4"
"$FFMPEG" -hide_banner -loglevel error -y -loop 1 -i "$TEST_ROOT/landscape-16x9.png" \
    -t 3 -c:v libx264 -pix_fmt yuv420p "$TEST_ROOT/fill-h264.mp4"
"$FFMPEG" -hide_banner -loglevel error -y -loop 1 -i "$TEST_ROOT/landscape-16x9.png" \
    -t 3 -c:v libsvtav1 -pix_fmt yuv420p "$TEST_ROOT/fill-av1.mp4"

cat > "$TEST_ROOT/list-screens.swift" <<'SWIFT'
import AppKit
for (index, screen) in NSScreen.screens.enumerated() {
    let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    print("\(index)\t\(number?.stringValue ?? "0")\t\(screen.localizedName)\t\(Int(screen.frame.width))\t\(Int(screen.frame.height))")
}
SWIFT
/usr/bin/swiftc "$TEST_ROOT/list-screens.swift" -o "$TEST_ROOT/list-screens" -framework AppKit >/dev/null
SCREEN_LINES=(${(f)"$("$TEST_ROOT/list-screens")"})
if [[ -n "${WALLPAPERMAC_TEST_DISPLAY_INDEX:-}" ]]; then
    TARGET_INDEX="$WALLPAPERMAC_TEST_DISPLAY_INDEX"
else
    # Prefer a portrait display: this is the regression scenario. Machines
    # with only landscape screens still run the general fit checks.
    TARGET_INDEX=0
    for (( i = 1; i <= ${#SCREEN_LINES}; i++ )); do
        IFS=$'\t' read -r _ _ _ width height <<< "${SCREEN_LINES[$i]}"
        if (( width < height )); then
            TARGET_INDEX=$(( i - 1 ))
            break
        fi
    done
fi
[[ "$TARGET_INDEX" == <-> ]] || { echo 'display index must be a non-negative integer' >&2; exit 1; }
(( TARGET_INDEX < ${#SCREEN_LINES} )) || { echo "display index $TARGET_INDEX is unavailable" >&2; exit 1; }
SCREEN_INFO="${SCREEN_LINES[$((TARGET_INDEX + 1))]}"
IFS=$'\t' read -r _ DISPLAY_NUMBER DISPLAY_NAME SCREEN_WIDTH SCREEN_HEIGHT <<< "$SCREEN_INFO"
if [[ "${WALLPAPERMAC_TEST_REQUIRE_PORTRAIT:-0}" == 1 ]] && (( SCREEN_WIDTH >= SCREEN_HEIGHT )); then
    echo "selected display $DISPLAY_NAME is not portrait: ${SCREEN_WIDTH}x${SCREEN_HEIGHT}" >&2
    exit 1
fi
printf 'testing display %s: %s (%sx%s)\n' "$TARGET_INDEX" "$DISPLAY_NAME" "$SCREEN_WIDTH" "$SCREEN_HEIGHT"

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

cat > "$TEST_ROOT/check-tile.swift" <<'SWIFT'
import AppKit
let path = CommandLine.arguments[1]
let windowWidth = Double(CommandLine.arguments[2])!
let windowHeight = Double(CommandLine.arguments[3])!
guard let image = NSImage(contentsOfFile: path), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("cannot read tile capture\n", stderr); exit(1)
}
let bitmap = NSBitmapImageRep(cgImage: cg)
// A tile renders at the source's native pixel size regardless of display
// backing scale: tile points = source pixels / contentScale, and capture
// pixels = points * the same scale.
let tileW = 32.0
let tileH = 16.0
if tileW < 8 || tileH < 8 { fputs("tile grid is too small to verify\n", stderr); exit(1) }
func color(_ x: Double, _ y: Double) -> NSColor? {
    bitmap.colorAt(x: Int(x), y: Int(y))
}
guard let first = color(tileW * 0.25, tileH * 0.25),
      let repeated = color(tileW * 1.25, tileH * 0.25),
      let other = color(tileW * 0.75, tileH * 0.25) else {
    fputs("tile sample points are unavailable\n", stderr); exit(1)
}
func close(_ a: NSColor, _ b: NSColor) -> Bool {
    abs(a.redComponent - b.redComponent) < 0.16 &&
    abs(a.greenComponent - b.greenComponent) < 0.16 &&
    abs(a.blueComponent - b.blueComponent) < 0.16
}
if !close(first, repeated) { fputs("tile did not repeat the source pattern\n", stderr); exit(1) }
if close(first, other) { fputs("capture is stretched or uniform instead of tiled\n", stderr); exit(1) }
print("tile pattern repeats at native size and preserves quadrant contrast")
SWIFT
/usr/bin/swiftc "$TEST_ROOT/check-tile.swift" -o "$TEST_ROOT/check-tile" -framework AppKit >/dev/null

cat > "$TEST_ROOT/check-fill.swift" <<'SWIFT'
import AppKit
let path = CommandLine.arguments[1]
let expectedMode = CommandLine.arguments[2]
let windowWidth = Double(CommandLine.arguments[3])!
let windowHeight = Double(CommandLine.arguments[4])!
guard let image = NSImage(contentsOfFile: path), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("cannot read fit capture\n", stderr); exit(1)
}
let bitmap = NSBitmapImageRep(cgImage: cg)
let bitmapWidth = Double(bitmap.pixelsWide)
let bitmapHeight = Double(bitmap.pixelsHigh)
func isNonBlack(_ x: Double, _ y: Double) -> Bool {
    guard let color = bitmap.colorAt(x: Int(x), y: Int(y)) else { return false }
    return max(color.redComponent, color.greenComponent, color.blueComponent) > 0.2
}
let left = isNonBlack(bitmapWidth * 0.01, bitmapHeight * 0.5)
let right = isNonBlack(bitmapWidth * 0.99, bitmapHeight * 0.5)
let top = isNonBlack(bitmapWidth * 0.5, bitmapHeight * 0.01)
let bottom = isNonBlack(bitmapWidth * 0.5, bitmapHeight * 0.99)
if expectedMode == "fill" {
    guard left && right && top && bottom else {
        fputs("fill left an empty viewport edge: left=\(left) right=\(right) top=\(top) bottom=\(bottom)\n", stderr); exit(1)
    }
} else {
    let viewportAspect = windowWidth / windowHeight
    let sourceAspect = 16.0 / 9.0
    if abs(viewportAspect - sourceAspect) < 0.02 {
        print("SKIPPED: viewport matches the 16:9 fixture; fit and fill are indistinguishable")
        exit(2)
    }
    if viewportAspect < sourceAspect {
        guard !top && !bottom && left && right else {
            fputs("fit did not preserve the expected horizontal letterbox\n", stderr); exit(1)
        }
    } else if viewportAspect > sourceAspect {
        guard !left && !right && top && bottom else {
            fputs("fit did not preserve the expected vertical letterbox\n", stderr); exit(1)
        }
    }
}
print("\(expectedMode) viewport coverage verified")
SWIFT
/usr/bin/swiftc "$TEST_ROOT/check-fill.swift" -o "$TEST_ROOT/check-fill" -framework AppKit >/dev/null

capture_item() {
    local source="$1"
    local type="$2"
    local label="$3"
    local global_mode="$4"
    local override_mode="$5"
    local library="$TEST_ROOT/Library-$label"
    mkdir -p "$library/Assets"
    python3 - "$library" "$source" "$type" "display-$DISPLAY_NUMBER" "$DISPLAY_NAME" "$override_mode" <<'PY'
import json, sys, uuid
from datetime import datetime, timezone
from pathlib import Path
library=Path(sys.argv[1]); source=Path(sys.argv[2]); kind=sys.argv[3]
now=datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace('+00:00','Z')
item_id=str(uuid.uuid4()).upper()
item={'id':item_id,'name':'fit fixture','type':kind,'sourceURL':source.as_uri(),'storageMode':'externalReference','availability':'available','createdAt':now,'isFavorite':False}
if sys.argv[6] != 'inherit':
    item['fitModeOverride']=sys.argv[6]
(library/'wallpapers.json').write_text(json.dumps([item],separators=(',',':')))
(library/'display-assignments.json').write_text(json.dumps([{'id':sys.argv[4],'displayName':sys.argv[5],'isConnected':True,'wallpaperID':item_id,'applicationState':'applied'}],separators=(',',':')))
PY
    defaults write com.wallpaper.mac 'WallpaperMac.libraryPath' -string "$library"
    defaults write com.wallpaper.mac 'WallpaperMac.onboardingCompleted' -bool YES
    defaults write com.wallpaper.mac 'WallpaperMac.fitMode' -string "$global_mode"
    "$EXEC" >"$TEST_ROOT/$label.log" 2>&1 &
    RUN_PID=$!
    WINDOW_INFO=""
    for _ in {1..80}; do
        WINDOW_INFO="$("$TEST_ROOT/list-wallpaper-windows")"
        [[ -n "$WINDOW_INFO" ]] && break
        sleep 0.25
    done
    [[ -n "$WINDOW_INFO" ]] || { echo "no wallpaper window for $label" >&2; cat "$TEST_ROOT/$label.log" >&2; exit 1; }
    sleep 1.5
    WINDOW_ID="$(print -r -- "$WINDOW_INFO" | awk -F '\t' '{print $1}')"
    WINDOW_WIDTH="$(print -r -- "$WINDOW_INFO" | awk -F '\t' '{print $2}')"
    WINDOW_HEIGHT="$(print -r -- "$WINDOW_INFO" | awk -F '\t' '{print $3}')"
    CAPTURE="$TEST_ROOT/$label.png"
    /usr/sbin/screencapture -x -o -l "$WINDOW_ID" "$CAPTURE"
    if [[ "$global_mode" == tile ]]; then
        "$TEST_ROOT/check-tile" "$CAPTURE" "$WINDOW_WIDTH" "$WINDOW_HEIGHT"
    else
        local effective_mode="$global_mode"
        [[ "$override_mode" == inherit ]] || effective_mode="$override_mode"
        if "$TEST_ROOT/check-fill" "$CAPTURE" "$effective_mode" "$WINDOW_WIDTH" "$WINDOW_HEIGHT"; then
            :
        else
            local rc=$?
            if (( rc == 2 )); then
                printf 'skipped fit check for %s: 16:9 viewport cannot distinguish fit from fill\n' "$label"
            else
                exit 1
            fi
        fi
    fi
    kill "$RUN_PID" 2>/dev/null || true
    wait "$RUN_PID" 2>/dev/null || true
    RUN_PID=""
    printf 'verified %s: global=%s override=%s\n' "$label" "$global_mode" "$override_mode"
}

capture_item "$TEST_ROOT/tile.png" image tile-image tile inherit
capture_item "$TEST_ROOT/tile-h264.mp4" video tile-h264 tile inherit
capture_item "$TEST_ROOT/tile-av1.mp4" video tile-av1 tile inherit
capture_item "$TEST_ROOT/landscape-16x9.png" image fill-image fill inherit
capture_item "$TEST_ROOT/fill-h264.mp4" video fill-h264 fill inherit
capture_item "$TEST_ROOT/fill-av1.mp4" video fill-av1 fill inherit
capture_item "$TEST_ROOT/landscape-16x9.png" image override-fit fill fit
capture_item "$TEST_ROOT/landscape-16x9.png" image override-fill fit fill
capture_item "$TEST_ROOT/landscape-16x9.png" image inherit-fit fit inherit
echo 'WALLPAPER_FIT_RUNTIME_TEST_PASSED'
