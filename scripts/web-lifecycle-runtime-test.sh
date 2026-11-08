#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXEC="$ROOT/dist/WallpaperMac.app/Contents/MacOS/WallpaperMac"
FFMPEG="${WALLPAPERMAC_FFMPEG:-/opt/homebrew/bin/ffmpeg}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wallpapermac-web-lifecycle.XXXXXX")"
LIBRARY="$TEST_ROOT/Library"
DEFAULTS_BACKUP="$TEST_ROOT/defaults.plist"
DEFAULTS_BACKED_UP=0
RUN_PID=""
SERVER_PID=""

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

cat > "$TEST_ROOT/server.py" <<'PY'
import http.server, sys, time
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/hold':
            time.sleep(30)
            try:
                self.send_response(204)
                self.end_headers()
            except BrokenPipeError:
                pass
            return
        with open(sys.argv[2], 'a') as f:
            f.write(self.path + '\n')
        self.send_response(204)
        self.end_headers()
    def log_message(self, *args):
        pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
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

"$FFMPEG" -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=640x360:rate=30' \
    -t 8 -c:v libx264 -pix_fmt yuv420p "$TEST_ROOT/clip.mp4"
SITE="$TEST_ROOT/site"
mkdir -p "$SITE"
cp "$TEST_ROOT/clip.mp4" "$SITE/clip.mp4"
cat > "$SITE/index.html" <<HTML
<!doctype html><html><body>
<video id="v" src="clip.mp4" autoplay muted loop playsinline></video>
<script>
new Image().src = 'http://127.0.0.1:$PORT/hold';
setInterval(() => {
  const v = document.getElementById('v');
  v.play().catch(() => {});
  new Image().src = 'http://127.0.0.1:$PORT/state?paused=' + v.paused + '&t=' + Date.now();
}, 700);
</script></body></html>
HTML

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
python3 - "$LIBRARY" "$SITE" "display-$DISPLAY_NUMBER" "$DISPLAY_NAME" <<'PY'
import json, sys, uuid
from datetime import datetime, timezone
from pathlib import Path
library = Path(sys.argv[1])
site = Path(sys.argv[2])
now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z')
item_id = str(uuid.uuid4()).upper()
item = {
    'id': item_id, 'name': 'Web lifecycle fixture', 'type': 'web',
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
"$EXEC" >"$TEST_ROOT/app.log" 2>&1 &
RUN_PID=$!

wait_for_media_state() {
    local expected="$1"
    for _ in {1..40}; do
        if [[ -f "$TEST_ROOT/requests" ]] && /usr/bin/grep -q "paused=$expected" "$TEST_ROOT/requests"; then
            return 0
        fi
        sleep 0.25
    done
    echo "media did not reach paused=$expected" >&2
    [[ ! -f "$TEST_ROOT/requests" ]] || tail -n 10 "$TEST_ROOT/requests" >&2
    return 1
}
click_menu_item() {
    local title="$1"
    osascript -e "tell application \"System Events\" to tell process \"WallpaperMac\"
        click menu bar item \"WM\" of menu bar 2
        delay 0.3
        click menu item \"$title\" of menu 1 of menu bar item \"WM\" of menu bar 2
    end tell"
}

wait_for_media_state false
click_menu_item '暂停动态壁纸'
wait_for_media_state true
# Repeated play() calls must not resume media while paused.
sleep 2
[[ "$(tail -n 1 "$TEST_ROOT/requests")" == *'paused=true'* ]] || { echo 'media resumed while paused' >&2; exit 1; }
click_menu_item '恢复动态壁纸'
wait_for_media_state false

# Renderer termination must trigger a bounded automatic recovery. Only kill a
# WebContent process directly parented by this test instance.
WEB_CONTENT_PID="$(lsof -nP -iTCP:"$PORT" 2>/dev/null | awk '/^com\.apple/ {print $2; exit}')"
[[ -n "$WEB_CONTENT_PID" ]] || { echo 'no test-owned WebContent process found' >&2; exit 1; }
BEFORE_RECOVERY="$(wc -l < "$TEST_ROOT/requests" | tr -d ' ')"
kill -9 "$WEB_CONTENT_PID"
RECOVERED=0
for _ in {1..40}; do
    COUNT="$(wc -l < "$TEST_ROOT/requests" | tr -d ' ')"
    if [[ "$COUNT" -gt "$BEFORE_RECOVERY" ]]; then RECOVERED=1; break; fi
    sleep 0.25
done
[[ "$RECOVERED" -eq 1 ]] || { echo 'WebContent did not recover after renderer termination' >&2; cat "$TEST_ROOT/app.log" >&2; exit 1; }
printf 'media_pause_resume=passed renderer_recovery=passed\n'
echo 'WEB_LIFECYCLE_RUNTIME_TEST_PASSED'
