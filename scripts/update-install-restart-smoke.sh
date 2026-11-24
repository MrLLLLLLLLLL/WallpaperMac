#!/bin/zsh
set -euo pipefail

# End-to-end installer tests using the production handoff: the probe acquires
# the target lock, writes and spawns install.sh, waits for its startup marker
# and exits; the detached script then performs the real copy, signature check,
# atomic swap, health handshake and relaunch. Everything runs in a temporary
# Applications directory and never touches /Applications.
#
# Phase 1: success. The old target's swap helper is replaced by a stub that
#          rejects --update-swap but forwards --update-lock-check. A correct
#          install must ignore the old helper, swap with the verified pending
#          build, keep .previous and restart the new version.
# Phase 2: failure. The payload's signature is broken; the install must keep
#          the old version, write a durable failure record, remove the failed
#          pending copy and relaunch the old app.
# Phase 3: startup failure. The installer cannot publish its marker; the app
#          must stay open and no duplicate failure record may remain.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/WallpaperMac.app"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wallpapermac-install-restart.XXXXXX")"
TARGET_PARENT="$TEST_ROOT/Applications"
TARGET="$TARGET_PARENT/WallpaperMac.app"
# LaunchServices resolves /var to /private/var, so match the unique test
# directory name instead of the absolute bundle path.
TARGET_MATCH="$(basename "$TEST_ROOT")/Applications/WallpaperMac.app/Contents/MacOS/WallpaperMac"
OLD_HELPER_LOG="$TEST_ROOT/old-helper.log"

DEFAULTS_BACKUP="$TEST_ROOT/defaults.plist"
DEFAULTS_BACKED_UP=0
CONFIG_DIR="$HOME/Library/Application Support/WallpaperMac/Configuration"
CONFIG_BACKUP="$TEST_ROOT/configuration-backup"
CONFIG_EXISTED=0
JOURNAL_DIR="$HOME/Library/Application Support/WallpaperMac/Update"
JOURNAL_BACKUP="$TEST_ROOT/update-journal-backup"
JOURNAL_EXISTED=0
RUN_PID=""

die() {
    echo "$1" >&2
    exit 1
}

stop_target_app() {
    local pid
    if [[ -n "$RUN_PID" ]] && kill -0 "$RUN_PID" 2>/dev/null; then
        kill "$RUN_PID" 2>/dev/null || true
        for _ in {1..50}; do
            kill -0 "$RUN_PID" 2>/dev/null || break
            sleep 0.1
        done
        kill -9 "$RUN_PID" 2>/dev/null || true
    fi
    RUN_PID=""
    for pid in $(pgrep -f "$TARGET_MATCH" 2>/dev/null || true); do
        kill "$pid" 2>/dev/null || true
    done
}

cleanup() {
    stop_target_app
    if (( DEFAULTS_BACKED_UP )) && [[ -s "$DEFAULTS_BACKUP" ]]; then
        defaults delete com.wallpaper.mac >/dev/null 2>&1 || true
        defaults import com.wallpaper.mac "$DEFAULTS_BACKUP" >/dev/null 2>&1 || true
    else
        defaults delete com.wallpaper.mac 'WallpaperMac.libraryPath' >/dev/null 2>&1 || true
        defaults delete com.wallpaper.mac 'WallpaperMac.onboardingCompleted' >/dev/null 2>&1 || true
        defaults delete com.wallpaper.mac 'WallpaperMac.autoCheckUpdates' >/dev/null 2>&1 || true
    fi
    if (( CONFIG_EXISTED )); then
        if [[ -d "$CONFIG_BACKUP" ]]; then
            rm -rf "$CONFIG_DIR"
            cp -R "$CONFIG_BACKUP" "$CONFIG_DIR" 2>/dev/null || true
        fi
    else
        rm -rf "$CONFIG_DIR"
    fi
    if (( JOURNAL_EXISTED )); then
        if [[ -d "$JOURNAL_BACKUP" ]]; then
            rm -rf "$JOURNAL_DIR"
            cp -R "$JOURNAL_BACKUP" "$JOURNAL_DIR" 2>/dev/null || true
        fi
    else
        rm -rf "$JOURNAL_DIR"
    fi
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT INT TERM

[[ -x "$APP/Contents/MacOS/WallpaperMac" ]] || die 'missing dist app; run package-release.sh first'
if pgrep -x WallpaperMac >/dev/null 2>&1; then
    die 'quit any running WallpaperMac instance before the install/restart test'
fi

defaults export com.wallpaper.mac "$DEFAULTS_BACKUP" >/dev/null 2>&1 && DEFAULTS_BACKED_UP=1
mkdir -p "$TEST_ROOT/Library" "$TARGET_PARENT"
if [[ -d "$CONFIG_DIR" ]]; then
    CONFIG_EXISTED=1
    cp -R "$CONFIG_DIR" "$CONFIG_BACKUP" || true
fi
if [[ -d "$JOURNAL_DIR" ]]; then
    JOURNAL_EXISTED=1
    if cp -R "$JOURNAL_DIR" "$JOURNAL_BACKUP"; then
        rm -rf "$JOURNAL_DIR"
    fi
fi
defaults write com.wallpaper.mac 'WallpaperMac.libraryPath' -string "$TEST_ROOT/Library"
defaults write com.wallpaper.mac 'WallpaperMac.onboardingCompleted' -bool YES
defaults write com.wallpaper.mac 'WallpaperMac.autoCheckUpdates' -bool NO

cd "$ROOT"
swift build --product WallpaperMacCoreTests >/dev/null
PROBE="$ROOT/.build/debug/WallpaperMacCoreTests"

installed_version() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null || true
}

reset_target() {
    rm -rf "$TARGET_PARENT"
    mkdir -p "$TARGET_PARENT"
    /usr/bin/ditto "$APP" "$TARGET"
}

make_payload() {
    local staging="$1"
    local version="$2"
    local source="$staging/extracted/WallpaperMac.app"
    mkdir -p "$staging/extracted"
    /usr/bin/ditto "$APP" "$source"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$source/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$source/Contents/Info.plist"
    /usr/bin/codesign --force --deep --sign - "$source" >/dev/null
    /usr/bin/codesign --verify --deep --strict "$source"
}

replace_old_helper_with_stub() {
    local real="$TARGET/Contents/MacOS/WallpaperMac"
    cat > "$real" <<EOF
#!/bin/zsh
print -r -- "\$@" >> "$OLD_HELPER_LOG"
if [[ "\$1" == "--update-lock-check" ]]; then
    exec "$APP/Contents/MacOS/WallpaperMac" --update-lock-check "\$2" "\$3"
fi
exit 1
EOF
    chmod +x "$real"
}

wait_for_target_app() {
    local pid
    RUN_PID=""
    for _ in {1..150}; do
        pid="$(
            pgrep -f "$TARGET_MATCH" 2>/dev/null | head -1 || true
        )"
        if [[ -n "$pid" ]]; then
            RUN_PID="$pid"
            return 0
        fi
        sleep 0.1
    done
    return 1
}

wait_for_success() {
    local staging="$1"
    local expected="$2"
    for _ in {1..300}; do
        if [[ ! -e "$staging" ]] && [[ "$(installed_version "$TARGET")" == "$expected" ]]; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

wait_for_no_stale_installing_siblings() {
    local stale=""
    for _ in {1..100}; do
        stale="$(find "$TARGET_PARENT" -maxdepth 1 -name "$(basename "$TARGET").installing.*" -print -quit 2>/dev/null || true)"
        [[ -z "$stale" ]] && return 0
        sleep 0.1
    done
    die "a failed pending copy was left behind: $stale"
}

# ---------------------------------------------------------------------------
# Phase 1: production handoff succeeds even when the old helper cannot swap.
# ---------------------------------------------------------------------------
PHASE1="$TEST_ROOT/success"
STAGING1="$PHASE1/staging"
RESULT1="$PHASE1/install-result.txt"

reset_target
replace_old_helper_with_stub
make_payload "$STAGING1" 9.9.9

"$PROBE" --launch-detached-probe \
    "$TARGET" "$STAGING1/extracted/WallpaperMac.app" "$STAGING1" 9.9.9 "$RESULT1" \
    > "$PHASE1/probe.log" 2>&1 || {
        cat "$PHASE1/probe.log" >&2
        die 'the production launch handoff failed'
    }
grep -q '^DETACHED_STARTED$' "$PHASE1/probe.log" || {
    cat "$PHASE1/probe.log" >&2
    die 'the installer did not publish its startup marker'
}

wait_for_success "$STAGING1" 9.9.9 || {
    cat "$STAGING1/install.log" >&2 2>/dev/null || true
    die 'detached install did not install and clean staging'
}
wait_for_target_app || {
    cat "$STAGING1/install.log" >&2 2>/dev/null || true
    die 'the installed app was not relaunched'
}

INSTALLED_VERSION="$(installed_version "$TARGET")"
[[ "$INSTALLED_VERSION" == "9.9.9" ]] || die "target version is $INSTALLED_VERSION, expected 9.9.9"
[[ ! -e "$RESULT1" ]] || die 'a successful install must not write a failure record'
[[ -d "$TARGET.previous" ]] || die 'old generation backup is missing'
PREVIOUS_VERSION="$(installed_version "$TARGET.previous")"
[[ "$PREVIOUS_VERSION" == "$VERSION" ]] || die "previous backup holds $PREVIOUS_VERSION, expected $VERSION"
[[ -x "$TARGET.previous/Contents/MacOS/WallpaperMac" ]] || die 'previous backup has no executable'
/usr/bin/codesign --verify --deep --strict "$TARGET" || die 'the installed app has an invalid signature'
grep -q -- '--update-lock-check' "$OLD_HELPER_LOG" 2>/dev/null || die 'the inherited install lock was never verified'
if grep -q -- '--update-swap' "$OLD_HELPER_LOG" 2>/dev/null; then
    die 'the broken old helper performed the swap'
fi
# The relaunched app must survive its first second, not just fork.
sleep 1
INSTANCE_COUNT="$(pgrep -f "$TARGET_MATCH" 2>/dev/null | wc -l | tr -d ' ')"
[[ "$INSTANCE_COUNT" == "1" ]] || die "expected exactly one running instance, found $INSTANCE_COUNT"
wait_for_no_stale_installing_siblings

echo "success_phase: installed=$INSTALLED_VERSION previous=$PREVIOUS_VERSION pid=$RUN_PID"
stop_target_app

# ---------------------------------------------------------------------------
# Phase 2: a broken payload keeps the old app, journals the failure and
# relaunches the old app.
# ---------------------------------------------------------------------------
PHASE2="$TEST_ROOT/failure"
STAGING2="$PHASE2/staging"
RESULT2="$PHASE2/install-result.txt"

reset_target
make_payload "$STAGING2" 9.9.9
# Invalidate the copied payload signature after signing.
rm -rf "$STAGING2/extracted/WallpaperMac.app/Contents/_CodeSignature"

"$PROBE" --launch-detached-probe \
    "$TARGET" "$STAGING2/extracted/WallpaperMac.app" "$STAGING2" 9.9.9 "$RESULT2" \
    > "$PHASE2/probe.log" 2>&1 || {
        cat "$PHASE2/probe.log" >&2
        die 'the production launch handoff failed for the failure scenario'
    }
grep -q '^DETACHED_STARTED$' "$PHASE2/probe.log" || {
    cat "$PHASE2/probe.log" >&2
    die 'the installer did not publish its startup marker'
}

for _ in {1..300}; do
    [[ -f "$RESULT2" ]] && break
    sleep 0.1
done
[[ -f "$RESULT2" ]] || {
    cat "$STAGING2/install.log" >&2 2>/dev/null || true
    die 'a failed install did not write a durable failure record'
}
wait_for_target_app || {
    cat "$STAGING2/install.log" >&2 2>/dev/null || true
    die 'a failed install did not relaunch the old app'
}
/usr/bin/grep -q '^state=failed$' "$RESULT2" || die 'the failure record has no failed state'
/usr/bin/grep -q '^version=9.9.9$' "$RESULT2" || die 'the failure record names the wrong version'
/usr/bin/grep -q '^message=.*signature' "$RESULT2" || die 'the failure record does not explain the signature failure'
/usr/bin/grep -q "^log=$STAGING2/install.log$" "$RESULT2" || die 'the failure record does not point at the install log'
[[ -f "$STAGING2/install.log" ]] || die 'a failed install must preserve its install.log'
[[ -e "$STAGING2" ]] || die 'a failed install must preserve its staging directory for diagnosis'
CURRENT_VERSION="$(installed_version "$TARGET")"
[[ "$CURRENT_VERSION" == "$VERSION" ]] || die "a failed install changed the target to $CURRENT_VERSION"
[[ ! -d "$TARGET.previous" ]] || die 'a pre-swap failure must not move the old app into .previous'
wait_for_no_stale_installing_siblings
echo "failure_phase: kept=$CURRENT_VERSION pid=$RUN_PID"
stop_target_app

# ---------------------------------------------------------------------------
# Phase 3: the installer cannot start at all. The app must stay open, report
# the handshake failure itself, and leave no duplicate failure record.
# ---------------------------------------------------------------------------
PHASE3="$TEST_ROOT/handshake"
STAGING3="$PHASE3/staging"
RESULT3="$PHASE3/install-result.txt"

reset_target
make_payload "$STAGING3" 9.9.9
# Make the installer's log redirect fail before it publishes its marker.
mkdir -p "$STAGING3/install.log"
HANDSHAKE_STATUS=0
"$PROBE" --launch-detached-probe \
    "$TARGET" "$STAGING3/extracted/WallpaperMac.app" "$STAGING3" 9.9.9 "$RESULT3" \
    > "$PHASE3/probe.log" 2>&1 || HANDSHAKE_STATUS=$?
[[ "$HANDSHAKE_STATUS" -ne 0 ]] || die 'the probe must fail when the installer cannot start'
grep -q '^DETACHED_FAILED' "$PHASE3/probe.log" || {
    cat "$PHASE3/probe.log" >&2
    die 'the probe did not report the installer startup failure'
}
[[ ! -e "$STAGING3/installer-started" ]] || die 'a failed installer must not publish its startup marker'
[[ ! -f "$RESULT3" ]] || die 'the app must remove the aborted installer journal it already reports in-process'
[[ "$(installed_version "$TARGET")" == "$VERSION" ]] || die 'a failed handshake must not touch the installed app'
wait_for_no_stale_installing_siblings

echo 'UPDATE_INSTALL_RESTART_SMOKE_PASSED'
