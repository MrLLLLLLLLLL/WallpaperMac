#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/WallpaperMac.app"
EXEC="$APP/Contents/MacOS/WallpaperMac"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wallpapermac-queue-pause.XXXXXX")"
LIBRARY="$TEST_ROOT/Library"
DEFAULTS_BACKUP="$TEST_ROOT/defaults.plist"
DEFAULTS_BACKED_UP=0
RUN_PID=""
TEXTEDIT_OPEN=0

cleanup() {
    if (( TEXTEDIT_OPEN )); then
        osascript -e 'tell application "TextEdit" to quit saving no' >/dev/null 2>&1 || true
    fi
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
defaults export com.wallpaper.mac "$DEFAULTS_BACKUP" >/dev/null 2>&1 && DEFAULTS_BACKED_UP=1
mkdir -p "$LIBRARY/Assets"

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

python3 - "$LIBRARY" "display-$DISPLAY_NUMBER" "$DISPLAY_NAME" <<'PY'
import json, sys, uuid
from datetime import datetime, timezone
from pathlib import Path
library = Path(sys.argv[1])
display_id = sys.argv[2]
display_name = sys.argv[3]
now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z')
items = []
for index in range(2):
    root = library.parent / f'pause-site-{index}'
    root.mkdir(parents=True, exist_ok=True)
    html = f'<html><body style="margin:0;background:rgb({30 + index * 70},20,60);color:white">Pause fixture {index}</body></html>'
    entry = root / 'index.html'
    entry.write_text(html)
    items.append({
        'id': str(uuid.uuid4()).upper(), 'name': f'Pause fixture {index}',
        'type': 'web', 'sourceURL': root.as_uri(), 'entryURL': entry.as_uri(),
        'storageMode': 'externalReference', 'availability': 'available',
        'createdAt': now, 'isFavorite': False,
    })
queue_id = str(uuid.uuid4()).upper()
(library / 'wallpapers.json').write_text(json.dumps(items, separators=(',', ':')))
(library / 'playback-queues.json').write_text(json.dumps([{
    'id': queue_id, 'name': 'Pause regression', 'isDefault': True,
    'wallpaperIDs': [item['id'] for item in items], 'sortMode': 'custom',
    'playbackMode': 'sequential', 'completionBehavior': 'loop',
    'advanceMode': 'fixedInterval', 'defaultIntervalSeconds': 1,
    'transition': 'cut', 'itemIntervalOverrides': [],
    'createdAt': now, 'updatedAt': now,
}], separators=(',', ':')))
(library / 'display-assignments.json').write_text('[]')
(library / 'display-playback-bindings.json').write_text(json.dumps([{
    'displayID': display_id, 'displayName': display_name, 'activeQueueID': queue_id,
    'queueStates': [queue_id, {
        'queueID': queue_id, 'currentIndex': 0,
        'isPlaying': True, 'isEnabled': True, 'overrides': {},
    }],
}], separators=(',', ':')))
PY

cat > "$TEST_ROOT/click-playback.swift" <<'SWIFT'
import AppKit
// Accessibility is exercised through the real menu item rather than an
// in-process notification, matching the user's menu-bar action.
let script = CommandLine.arguments[1]
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
process.arguments = ["-e", script]
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
SWIFT
/usr/bin/swiftc "$TEST_ROOT/click-playback.swift" -o "$TEST_ROOT/click-playback" -framework AppKit >/dev/null

defaults write com.wallpaper.mac 'WallpaperMac.libraryPath' -string "$LIBRARY"
defaults write com.wallpaper.mac 'WallpaperMac.onboardingCompleted' -bool YES
defaults write com.wallpaper.mac 'WallpaperMac.pauseInFullScreen' -bool YES
open -n "$APP"
for _ in {1..40}; do
    RUN_PID="$(pgrep -x WallpaperMac | head -1 || true)"
    [[ -n "$RUN_PID" ]] && break
    sleep 0.25
done
[[ -n "$RUN_PID" ]] || { echo 'WallpaperMac did not start' >&2; exit 1; }

read_queue_state() {
    python3 - "$LIBRARY/display-playback-bindings.json" <<'PY'
import json, sys
binding = json.load(open(sys.argv[1]))[0]
state = binding['queueStates'][1]
print(f"{state.get('currentIndex', -1)}\t{state.get('isEnabled', False)}\t{state.get('isPlaying', False)}")
PY
}

click_menu_item() {
    local title="$1"
    "$TEST_ROOT/click-playback" "tell application \"System Events\" to tell process \"WallpaperMac\"
        click menu bar item \"WM\" of menu bar 2
        delay 0.2
        click menu item \"$title\" of menu 1 of menu bar item \"WM\" of menu bar 2
    end tell"
}

# Wait for the first real advance before pausing.
ADVANCED=0
for _ in {1..40}; do
    INDEX="$(read_queue_state | awk -F '\t' '{print $1}')"
    if [[ "$INDEX" -gt 0 ]]; then ADVANCED=1; break; fi
    sleep 0.25
done
[[ "$ADVANCED" -eq 1 ]] || { echo 'queue never advanced before pause' >&2; read_queue_state >&2; exit 1; }

click_menu_item '暂停动态壁纸'
sleep 0.5
PAUSED_STATE="$(read_queue_state)"
PAUSED_INDEX="$(print -r -- "$PAUSED_STATE" | awk -F '\t' '{print $1}')"
sleep 3
AFTER_WAIT="$(read_queue_state)"
AFTER_INDEX="$(print -r -- "$AFTER_WAIT" | awk -F '\t' '{print $1}')"
[[ "$AFTER_INDEX" -eq "$PAUSED_INDEX" ]] || { echo 'queue advanced while paused' >&2; print -r -- "$PAUSED_STATE -> $AFTER_WAIT" >&2; exit 1; }
print -r -- "$AFTER_WAIT" | awk -F '\t' '$2 != "True" { exit 1 }' || { echo 'manual pause permanently disabled the queue' >&2; print -r -- "$AFTER_WAIT" >&2; exit 1; }
print -r -- "$AFTER_WAIT" | awk -F '\t' '$3 != "False" { exit 1 }' || { echo 'manual pause did not update isPlaying' >&2; print -r -- "$AFTER_WAIT" >&2; exit 1; }

click_menu_item '恢复动态壁纸'
RESUMED=0
for _ in {1..40}; do
    INDEX="$(read_queue_state | awk -F '\t' '{print $1}')"
    if [[ "$INDEX" -ne "$PAUSED_INDEX" ]]; then RESUMED=1; break; fi
    sleep 0.25
done
[[ "$RESUMED" -eq 1 ]] || { echo 'queue did not advance after resume' >&2; read_queue_state >&2; exit 1; }
FINAL_STATE="$(read_queue_state)"
print -r -- "$FINAL_STATE" | awk -F '\t' '$2 != "True" || $3 != "True" { exit 1 }' || { echo 'resume did not restore enabled/playing state' >&2; print -r -- "$FINAL_STATE" >&2; exit 1; }
printf 'paused_index=%s after_wait=%s resumed_index=%s\n' "$PAUSED_INDEX" "$AFTER_INDEX" "$INDEX"
echo 'QUEUE_PAUSE_RUNTIME_TEST_PASSED'

# Exercise the separate system-suspension path with a real full-screen app.
open -a TextEdit
TEXTEDIT_OPEN=1
sleep 1
osascript -e 'tell application "TextEdit" to activate' -e 'tell application "System Events" to keystroke "f" using {command down, control down}'
sleep 2
SUSPENDED_STATE="$(read_queue_state)"
SUSPENDED_INDEX="$(print -r -- "$SUSPENDED_STATE" | awk -F '\t' '{print $1}')"
sleep 3
SUSPENDED_WAIT="$(read_queue_state)"
SUSPENDED_AFTER_INDEX="$(print -r -- "$SUSPENDED_WAIT" | awk -F '\t' '{print $1}')"
[[ "$SUSPENDED_AFTER_INDEX" -eq "$SUSPENDED_INDEX" ]] || { echo 'queue advanced during full-screen suspension' >&2; print -r -- "$SUSPENDED_STATE -> $SUSPENDED_WAIT" >&2; exit 1; }
print -r -- "$SUSPENDED_WAIT" | awk -F '\t' '$2 != "True" || $3 != "True" { exit 1 }' || { echo 'system suspension changed the saved user intent' >&2; print -r -- "$SUSPENDED_WAIT" >&2; exit 1; }

osascript -e 'tell application "TextEdit" to quit saving no'
TEXTEDIT_OPEN=0
SYSTEM_RESUMED=0
for _ in {1..40}; do
    INDEX="$(read_queue_state | awk -F '\t' '{print $1}')"
    if [[ "$INDEX" -ne "$SUSPENDED_INDEX" ]]; then SYSTEM_RESUMED=1; break; fi
    sleep 0.25
done
[[ "$SYSTEM_RESUMED" -eq 1 ]] || { echo 'queue did not resume after full-screen exit' >&2; read_queue_state >&2; exit 1; }
printf 'full_screen_suspended_index=%s after_exit_index=%s\n' "$SUSPENDED_INDEX" "$INDEX"
echo 'QUEUE_SYSTEM_PAUSE_RUNTIME_TEST_PASSED'
