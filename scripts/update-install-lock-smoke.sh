#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wallpapermac-lock-smoke.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

cd "$ROOT"
swift build --product WallpaperMacCoreTests >/dev/null
PROBE="$ROOT/.build/debug/WallpaperMacCoreTests"
TARGET="$TEST_ROOT/WallpaperMac.app"
mkdir -p "$TARGET"
printf 'old-complete\n' > "$TARGET/marker.txt"

"$PROBE" --update-lock-probe "$TARGET" >"$TEST_ROOT/first.log" 2>&1 &
FIRST_PID=$!
for _ in {1..40}; do
    grep -q '^LOCKED ' "$TEST_ROOT/first.log" && break
    sleep 0.05
done
grep -q '^LOCKED ' "$TEST_ROOT/first.log"

if "$PROBE" --update-lock-probe "$TARGET" >"$TEST_ROOT/second.log" 2>&1; then
    echo 'second process unexpectedly acquired an occupied lock' >&2
    exit 1
fi
grep -q '已有安装流程正在进行' "$TEST_ROOT/second.log"
wait "$FIRST_PID"

"$PROBE" --update-lock-probe "$TARGET" >"$TEST_ROOT/third.log" 2>&1
grep -q '^LOCKED ' "$TEST_ROOT/third.log"
printf 'occupied lock rejected; lock released after owner exit\n'
echo 'UPDATE_INSTALL_LOCK_SMOKE_PASSED'
