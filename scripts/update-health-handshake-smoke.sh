#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXEC="$ROOT/dist/WallpaperMac.app/Contents/MacOS/WallpaperMac"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wallpapermac-health-handshake.XXXXXX")"
TOKEN="$(/usr/bin/uuidgen)"
ACK="$TEST_ROOT/ack.txt"
DEFAULTS_BACKUP="$TEST_ROOT/defaults.plist"
DEFAULTS_BACKED_UP=0
RUN_PID=""

cleanup() {
    if [[ -n "$RUN_PID" ]] && kill -0 "$RUN_PID" 2>/dev/null; then
        kill "$RUN_PID" 2>/dev/null || true
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
defaults export com.wallpaper.mac "$DEFAULTS_BACKUP" >/dev/null 2>&1 && DEFAULTS_BACKED_UP=1
mkdir -p "$TEST_ROOT/Library"
defaults write com.wallpaper.mac 'WallpaperMac.libraryPath' -string "$TEST_ROOT/Library"
defaults write com.wallpaper.mac 'WallpaperMac.onboardingCompleted' -bool YES

"$EXEC" --update-health-token "$TOKEN" --update-health-file "$ACK" >"$TEST_ROOT/app.log" 2>&1 &
RUN_PID=$!
HEALTHY=0
for _ in {1..50}; do
    if [[ -f "$ACK" ]] \
        && /usr/bin/grep -q "^token=$TOKEN$" "$ACK" \
        && /usr/bin/grep -q "^pid=$RUN_PID$" "$ACK" \
        && /usr/bin/grep -q "^version=$VERSION$" "$ACK"; then
        HEALTHY=1
        break
    fi
    sleep 0.2
done
[[ "$HEALTHY" -eq 1 ]] || { echo 'new app did not acknowledge its health token' >&2; cat "$TEST_ROOT/app.log" >&2; exit 1; }
printf 'health acknowledgement token=%s pid=%s version=%s\n' "$TOKEN" "$RUN_PID" "$VERSION"
echo 'UPDATE_HEALTH_HANDSHAKE_PASSED'
