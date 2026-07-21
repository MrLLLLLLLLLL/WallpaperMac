#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/WallpaperMac.app"
EXEC="$APP/Contents/MacOS/WallpaperMac"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wallpapermac-player-test.XXXXXX")"
LIBRARY="$TEST_ROOT/Library"
DIAGNOSTIC_DIR="$HOME/Library/Logs/DiagnosticReports"
DEFAULTS_BACKUP="$TEST_ROOT/defaults.plist"
DEFAULTS_BACKED_UP=0
RUN_PID=""

cleanup() {
    if [[ -n "$RUN_PID" ]] && kill -0 "$RUN_PID" 2>/dev/null; then
        kill "$RUN_PID" 2>/dev/null || true
        for _ in {1..15}; do
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

list_pids() {
    pgrep -x WallpaperMac || true
}

wait_for_new_pid() {
    local -a before_pids after_pids
    before_pids=($(list_pids))
    open -n "$APP"
    for _ in {1..40}; do
        after_pids=($(list_pids))
        for pid in $after_pids; do
            if (( ${before_pids[(Ie)$pid]} == 0 )); then
                print -r -- "$pid"
                return 0
            fi
        done
        sleep 0.25
    done
    return 1
}

stop_run_pid() {
    if [[ -z "$RUN_PID" ]]; then return; fi
    if kill -0 "$RUN_PID" 2>/dev/null; then
        kill "$RUN_PID" 2>/dev/null || true
        for _ in {1..15}; do
            kill -0 "$RUN_PID" 2>/dev/null || break
            sleep 0.2
        done
    fi
    RUN_PID=""
}

cd "$ROOT"
test -x "$EXEC"
/usr/bin/codesign --verify --deep --strict "$APP"

defaults export com.wallpaper.mac "$DEFAULTS_BACKUP" >/dev/null 2>&1 && DEFAULTS_BACKED_UP=1
mkdir -p "$LIBRARY/Assets" "$TEST_ROOT/site"

echo '== Build runtime fixtures =='
printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=' | base64 -D > "$TEST_ROOT/image.png"
cat > "$TEST_ROOT/site/index.html" <<'HTML'
<!doctype html>
<html lang="zh-CN"><meta charset="utf-8"><title>WallpaperMac Runtime</title>
<style>html,body{margin:0;width:100%;height:100%;background:#111;color:#7aa7ff;font:32px -apple-system;text-align:center}body{display:grid;place-items:center}</style>
<body>WallpaperMac Web Runtime</body>
HTML

cat > "$TEST_ROOT/make-video.swift" <<'SWIFT'
import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.removeItem(at: output)
let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
let settings: [String: Any] = [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: 640,
    AVVideoHeightKey: 360,
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 500_000,
        AVVideoExpectedSourceFrameRateKey: 10,
        AVVideoMaxKeyFrameIntervalKey: 10
    ]
]
let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
    kCVPixelBufferWidthKey as String: 640,
    kCVPixelBufferHeightKey as String: 360,
    kCVPixelBufferCGImageCompatibilityKey as String: true,
    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)
for frame in 0..<20 {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 640, 360, kCVPixelFormatType_32ARGB, nil, &buffer)
    guard let buffer else { fatalError("Unable to create pixel buffer") }
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt32.self)
    let color = frame % 2 == 0 ? UInt32(0xFF2A72E5) : UInt32(0xFFB341D8)
    for index in 0..<(640 * 360) { base[index] = color }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
}
input.markAsFinished()
let group = DispatchGroup()
group.enter()
writer.finishWriting { group.leave() }
group.wait()
if writer.status != .completed { fatalError(writer.error?.localizedDescription ?? "Unable to finish video") }
SWIFT
swiftc "$TEST_ROOT/make-video.swift" -o "$TEST_ROOT/make-video" -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework Foundation >/dev/null
"$TEST_ROOT/make-video" "$TEST_ROOT/wallpaper.mp4"

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
    echo 'ERROR: no display is available for player runtime test.' >&2
    exit 1
fi
DISPLAY_NUMBER="$(print -r -- "$SCREEN_INFO" | awk -F '\t' '{print $2}')"
DISPLAY_NAME="$(print -r -- "$SCREEN_INFO" | awk -F '\t' '{print $3}')"
DISPLAY_ID="display-$DISPLAY_NUMBER"

python3 - "$TEST_ROOT" "$LIBRARY" "$DISPLAY_ID" "$DISPLAY_NAME" <<'PY'
import json, sys, uuid
from datetime import datetime, timezone
from pathlib import Path
root = Path(sys.argv[1])
library = Path(sys.argv[2])
display_id, display_name = sys.argv[3:]
now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z')
items = []
for name, kind, source, entry in [
    ('Runtime Image', 'image', root / 'image.png', None),
    ('Runtime Video', 'video', root / 'wallpaper.mp4', None),
    ('Runtime Web', 'web', root / 'site', root / 'site' / 'index.html'),
]:
    item = {
        'id': str(uuid.uuid4()).upper(),
        'name': name,
        'type': kind,
        'sourceURL': source.as_uri(),
        'storageMode': 'externalReference',
        'availability': 'available',
        'createdAt': now,
        'isFavorite': False,
    }
    if entry is not None:
        item['entryURL'] = entry.as_uri()
    items.append(item)
(library / 'wallpapers.json').write_text(json.dumps(items, separators=(',', ':')))
(library / 'display-assignments.json').write_text('[]')
(root / 'items.json').write_text(json.dumps(items, indent=2))
PY

cat > "$TEST_ROOT/list-wallpaper-windows.swift" <<'SWIFT'
import CoreGraphics
let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
for item in windows {
    guard let owner = item[kCGWindowOwnerName as String] as? String, owner == "WallpaperMac" else { continue }
    let layer = item[kCGWindowLayer as String] as? Int ?? -1
    print("layer=\(layer)")
}
SWIFT
swiftc "$TEST_ROOT/list-wallpaper-windows.swift" -o "$TEST_ROOT/list-wallpaper-windows" -framework CoreGraphics >/dev/null

find "$DIAGNOSTIC_DIR" -maxdepth 1 -name 'WallpaperMac-*.ips' -print 2>/dev/null | sort > "$TEST_ROOT/diagnostics-before.txt"

verify_persisted_metadata() {
    local kind="$1"
    python3 - "$LIBRARY/wallpapers.json" "$kind" "$LIBRARY" <<'PY'
import json
import sys
from pathlib import Path
from urllib.parse import urlparse

items = json.loads(Path(sys.argv[1]).read_text())
kind = sys.argv[2]
library = Path(sys.argv[3])
item = next(item for item in items if item['type'] == kind)
metadata = item.get('metadata') or {}
expected_extension = 'png' if kind == 'image' else 'mp4'
expected_width = 1 if kind == 'image' else 640
expected_height = 1 if kind == 'image' else 360
if metadata.get('fileExtension') != expected_extension:
    raise SystemExit(f"unexpected extension: {metadata}")
if not metadata.get('fileSizeBytes'):
    raise SystemExit(f"missing file size: {metadata}")
if metadata.get('pixelWidth') != expected_width or metadata.get('pixelHeight') != expected_height:
    raise SystemExit(f"unexpected dimensions: {metadata}")
if kind == 'video':
    if not metadata.get('durationSeconds') or not item.get('thumbnailURL'):
        raise SystemExit(f"missing video duration or thumbnail URL: {item}")
    thumbnail = Path(urlparse(item['thumbnailURL']).path)
    if not thumbnail.is_file() or thumbnail.parent != library / 'Thumbnails':
        raise SystemExit(f"missing generated thumbnail: {thumbnail}")
PY
}

echo '== Exercise image, video and web wallpaper windows =='
for TYPE in image video web; do
    stop_run_pid
    ITEM_ID="$(python3 - "$TEST_ROOT/items.json" "$TYPE" <<'PY'
import json, sys
items = json.load(open(sys.argv[1]))
print(next(item['id'] for item in items if item['type'] == sys.argv[2]))
PY
)"
    python3 - "$LIBRARY/display-assignments.json" "$DISPLAY_ID" "$DISPLAY_NAME" "$ITEM_ID" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
path.write_text(json.dumps([{
    'id': sys.argv[2],
    'displayName': sys.argv[3],
    'isConnected': True,
    'wallpaperID': sys.argv[4],
    'applicationState': 'applied',
}], separators=(',', ':')))
PY
    defaults write com.wallpaper.mac 'WallpaperMac.libraryPath' -string "$LIBRARY"
    defaults write com.wallpaper.mac 'WallpaperMac.onboardingCompleted' -bool YES
    RUN_PID="$(wait_for_new_pid)"
    sleep 3
    if ! kill -0 "$RUN_PID" 2>/dev/null; then
        echo "ERROR: process exited while testing $TYPE wallpaper." >&2
        exit 1
    fi
    WINDOW_COUNT="$("$TEST_ROOT/list-wallpaper-windows" | awk '/layer=-2147483623/ { count += 1 } END { print count + 0 }')"
    if (( WINDOW_COUNT < 1 )); then
        echo "ERROR: no wallpaper window was created for $TYPE wallpaper." >&2
        exit 1
    fi
    STATE="$(python3 - "$LIBRARY/display-assignments.json" <<'PY'
import json, sys
items = json.load(open(sys.argv[1]))
print(items[0]['applicationState'] if items else 'none')
PY
)"
    if [[ "$STATE" != applied ]]; then
        echo "ERROR: display assignment did not remain applied for $TYPE wallpaper." >&2
        exit 1
    fi
    if [[ "$TYPE" == image || "$TYPE" == video ]]; then
        metadata_ready=0
        for _ in {1..20}; do
            if verify_persisted_metadata "$TYPE"; then
                metadata_ready=1
                break
            fi
            sleep 0.25
        done
        if (( metadata_ready == 0 )); then
            echo "ERROR: $TYPE metadata or video thumbnail was not persisted." >&2
            exit 1
        fi
    fi
    echo "$TYPE: PID=$RUN_PID wallpaperWindows=$WINDOW_COUNT assignment=$STATE"
done

find "$DIAGNOSTIC_DIR" -maxdepth 1 -name 'WallpaperMac-*.ips' -print 2>/dev/null | sort > "$TEST_ROOT/diagnostics-after.txt"
NEW_REPORTS=()
while IFS= read -r report; do
    [[ -z "$report" ]] && continue
    if ! grep -Fqx "$report" "$TEST_ROOT/diagnostics-before.txt"; then
        NEW_REPORTS+=("$report")
    fi
done < "$TEST_ROOT/diagnostics-after.txt"
if (( ${#NEW_REPORTS} > 0 )); then
    echo 'ERROR: player runtime test generated new DiagnosticReport files:' >&2
    printf '  %s\n' $NEW_REPORTS >&2
    exit 1
fi

stop_run_pid
echo 'No new WallpaperMac DiagnosticReport was generated.'
echo 'PLAYER_RUNTIME_MATRIX_PASSED'
