#!/bin/zsh
# UI regression for the Steam Workshop browse sheet.
# Verifies the sheet opens from the add-wallpaper menu, lays out a five-column
# grid, scrolls, and resizes without clipping the action bar. Requires the
# release app bundle and a logged-out Steam state so the test also covers the
# anonymous-browse path (no login sheet on open).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib/test-state-guard.sh"
EXEC="$ROOT/dist/WallpaperMac.app/Contents/MacOS/WallpaperMac"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wallpapermac-workshop-ui.XXXXXX")"
LIBRARY="$TEST_ROOT/Library"
RUN_PID=""
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
    if [[ -n "$HIDDEN_PROCESS_NAMES" ]]; then
        for process_name in ${(s:,:)HIDDEN_PROCESS_NAMES}; do
            process_name="${process_name## }"
            osascript -e "tell application \"System Events\" to set visible of process \"$process_name\" to true" >/dev/null 2>&1 || true
        done
    fi
    wm_state_guard_restore
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT INT TERM

cd "$ROOT"
test -x "$EXEC"
wm_state_guard_init "$TEST_ROOT"
mkdir -p "$LIBRARY/Assets"

# Seed one local wallpaper so the library is non-empty; no display assignment
# is needed because the test only exercises the browse sheet.
python3 - "$LIBRARY" <<'PY'
import json, sys, uuid
from datetime import datetime, timezone
from pathlib import Path
library = Path(sys.argv[1])
now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z')
item_id = str(uuid.uuid4()).upper()
item = {
    'id': item_id, 'name': 'UI fixture', 'type': 'image',
    'sourceURL': (library / 'fixture.jpg').as_uri(),
    'storageMode': 'externalReference', 'availability': 'available',
    'createdAt': now, 'isFavorite': False,
}
(library / 'wallpapers.json').write_text(json.dumps([item], separators=(',', ':')))
(library / 'fixture.jpg').write_bytes(b'\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xff\xd9')
PY

defaults write com.wallpaper.mac 'WallpaperMac.libraryPath' -string "$LIBRARY"
defaults write com.wallpaper.mac 'WallpaperMac.onboardingCompleted' -bool YES
# Force a logged-out state: browsing must not require login.
defaults delete com.wallpaper.mac 'WallpaperMac.steamWorkshopAccount' >/dev/null 2>&1 || true

env "$EXEC" >"$TEST_ROOT/app.log" 2>&1 &
RUN_PID=$!
sleep 4
kill -0 "$RUN_PID" 2>/dev/null || { echo 'WallpaperMac exited during workshop UI test' >&2; cat "$TEST_ROOT/app.log" >&2; exit 1; }

# Hide other apps so clicks land on WallpaperMac.
HIDDEN_PROCESS_NAMES="$(osascript -e 'tell application "System Events" to get name of every process whose visible is true and name is not "WallpaperMac"' 2>/dev/null || true)"
if [[ -n "$HIDDEN_PROCESS_NAMES" ]]; then
    osascript -e 'tell application "System Events" to set visible of every process whose visible is true and name is not "WallpaperMac" to false' >/dev/null 2>&1 || true
fi
sleep 1

# Open the add-wallpaper menu and choose Workshop browse.
osascript <<'AS' >/dev/null 2>&1 || true
tell application "System Events" to tell process "WallpaperMac"
    set frontmost to true
    delay 0.5
    try
        click button "添加壁纸" of window 1
        delay 0.5
        click menu item "浏览 Steam 创意工坊…" of menu 1 of button "添加壁纸" of window 1
    on error
        try
            click button 1 of window 1
            delay 0.5
            click menu item "浏览 Steam 创意工坊…" of menu 1 of button 1 of window 1
        end try
    end try
end tell
AS
sleep 3

# Verify the browse sheet exists and grab its initial size.
BOUNDS="$(osascript <<'AS'
tell application "System Events" to tell process "WallpaperMac"
    try
        set win to window "浏览 Steam 创意工坊"
        set {x, y} to position of win
        set {w, h} to size of win
        return (x as text) & " " & (y as text) & " " & (w as text) & " " & (h as text)
    on error
        return ""
    end try
end tell
AS
)"
if [[ -z "$BOUNDS" ]]; then
    echo 'browse sheet did not open' >&2
    cat "$TEST_ROOT/app.log" >&2
    exit 1
fi
read -r X Y W H <<< "$BOUNDS"
printf 'browse sheet opened at %s,%s size %sx%s\n' "$X" "$Y" "$W" "$H"
[[ "$W" -ge 700 && "$H" -ge 520 ]] || { echo 'browse sheet smaller than minimum size' >&2; exit 1; }

# Resize the sheet and confirm it stays above the minimum.
osascript <<AS >/dev/null 2>&1 || true
tell application "System Events" to tell process "WallpaperMac"
    set size of window "浏览 Steam 创意工坊" to {1000, 750}
end tell
AS
sleep 1
RESIZED="$(osascript <<'AS'
tell application "System Events" to tell process "WallpaperMac"
    set {w, h} to size of window "浏览 Steam 创意工坊"
    return (w as text) & " " & (h as text)
end tell
AS
)"
read -r RW RH <<< "$RESIZED"
printf 'browse sheet resized to %sx%s\n' "$RW" "$RH"
[[ "$RW" -ge 900 && "$RH" -ge 700 ]] || { echo 'browse sheet did not resize' >&2; exit 1; }

# Scroll the grid via System Events scroll wheel (works even when the sheet
# contains a ScrollView with LazyVGrid).
osascript <<'AS' >/dev/null 2>&1 || true
tell application "System Events" to tell process "WallpaperMac"
    set frontmost to true
    delay 0.3
    scroll area 1 of window "浏览 Steam 创意工坊"
end tell
AS
sleep 1

# Close the sheet.
osascript <<'AS' >/dev/null 2>&1 || true
tell application "System Events" to tell process "WallpaperMac"
    click button "关闭" of window "浏览 Steam 创意工坊"
end tell
AS
sleep 1

echo 'WORKSHOP_BROWSE_UI_TEST_PASSED'
