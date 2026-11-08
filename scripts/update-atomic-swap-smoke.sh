#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXEC="$ROOT/dist/WallpaperMac.app/Contents/MacOS/WallpaperMac"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wallpapermac-atomic-swap.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

test -x "$EXEC"
make_app() {
    local app="$1"
    local version="$2"
    local marker="$3"
    mkdir -p "$app/Contents/MacOS"
    cp "$EXEC" "$app/Contents/MacOS/WallpaperMac"
    chmod +x "$app/Contents/MacOS/WallpaperMac"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleShortVersionString string' "$app/Contents/Info.plist" >/dev/null
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string WallpaperMac' "$app/Contents/Info.plist"
    print -r -- "$marker" > "$app/Contents/MacOS/marker.txt"
}

make_app "$TEST_ROOT/Pending.app" '2.0.0' 'new-complete'
make_app "$TEST_ROOT/WallpaperMac.app" '1.0.0' 'old-complete'

"$EXEC" --update-swap "$TEST_ROOT/Pending.app" "$TEST_ROOT/WallpaperMac.app"
[[ "$(cat "$TEST_ROOT/WallpaperMac.app/Contents/MacOS/marker.txt")" == 'new-complete' ]] || {
    echo 'atomic swap did not install the new app' >&2
    exit 1
}
[[ "$(cat "$TEST_ROOT/Pending.app/Contents/MacOS/marker.txt")" == 'old-complete' ]] || {
    echo 'atomic swap did not retain the old app' >&2
    exit 1
}

"$EXEC" --update-swap "$TEST_ROOT/Pending.app" "$TEST_ROOT/WallpaperMac.app"
[[ "$(cat "$TEST_ROOT/WallpaperMac.app/Contents/MacOS/marker.txt")" == 'old-complete' ]] || {
    echo 'atomic rollback did not restore the old app' >&2
    exit 1
}
[[ "$(cat "$TEST_ROOT/Pending.app/Contents/MacOS/marker.txt")" == 'new-complete' ]] || {
    echo 'atomic rollback did not retain the failed new app' >&2
    exit 1
}
echo 'UPDATE_ATOMIC_SWAP_SMOKE_PASSED'
