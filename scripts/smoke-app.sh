#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/WallpaperMac.app"
EXEC="$APP/Contents/MacOS/WallpaperMac"
DIAGNOSTIC_DIR="$HOME/Library/Logs/DiagnosticReports"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${TMPDIR:-/tmp}/wallpapermac-smoke-${STAMP}.log"
BEFORE_FILE="${TMPDIR:-/tmp}/wallpapermac-diagnostics-before-${STAMP}.txt"
AFTER_FILE="${TMPDIR:-/tmp}/wallpapermac-diagnostics-after-${STAMP}.txt"
STARTED_PIDS=()

cleanup() {
    for pid in $STARTED_PIDS; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            for _ in {1..10}; do
                kill -0 "$pid" 2>/dev/null || break
                sleep 0.2
            done
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
}
trap cleanup EXIT INT TERM

list_app_pids() {
    ps -axo pid=,command= | awk -v executable="$EXEC" 'index($0, executable) { print $1 }'
}

list_diagnostics() {
    if [[ -d "$DIAGNOSTIC_DIR" ]]; then
        find "$DIAGNOSTIC_DIR" -maxdepth 1 -name 'WallpaperMac-*.ips' -print | sort
    fi
}

cd "$ROOT"

echo '== App smoke test =='
test -d "$APP"
test -x "$EXEC"
/usr/bin/codesign --verify --deep --strict "$APP"

list_diagnostics > "$BEFORE_FILE"
BEFORE_PIDS=($(list_app_pids))

echo "Launching: $APP"
open -n "$APP"

RUNNING_PID=""
for _ in {1..25}; do
    AFTER_PIDS=($(list_app_pids))
    for pid in $AFTER_PIDS; do
        if (( ${BEFORE_PIDS[(Ie)$pid]} == 0 )); then
            RUNNING_PID="$pid"
            break
        fi
    done
    [[ -n "$RUNNING_PID" ]] && break
    sleep 0.2
done

if [[ -z "$RUNNING_PID" ]]; then
    echo 'ERROR: WallpaperMac process did not start.' >&2
    exit 1
fi
STARTED_PIDS+=("$RUNNING_PID")

echo "Started PID: $RUNNING_PID"
sleep 4

if ! kill -0 "$RUNNING_PID" 2>/dev/null; then
    echo 'ERROR: WallpaperMac exited during the smoke-test window.' >&2
    if [[ -f "$LOG_FILE" ]]; then
        cat "$LOG_FILE" >&2
    fi
    exit 1
fi

list_diagnostics > "$AFTER_FILE"
NEW_DIAGNOSTICS=()
while IFS= read -r report; do
    [[ -z "$report" ]] && continue
    if ! grep -Fqx "$report" "$BEFORE_FILE"; then
        NEW_DIAGNOSTICS+=("$report")
    fi
done < "$AFTER_FILE"

if (( ${#NEW_DIAGNOSTICS} > 0 )); then
    echo 'ERROR: New WallpaperMac DiagnosticReport files were generated:' >&2
    printf '  %s\n' $NEW_DIAGNOSTICS >&2
    exit 1
fi

echo 'Process remained alive for 4 seconds.'
echo 'No new WallpaperMac DiagnosticReport was generated.'
echo 'APP_SMOKE_PASSED'
