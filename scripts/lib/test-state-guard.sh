#!/bin/zsh
# Shared backup/restore guard for runtime test scripts.
#
# Every runtime test writes com.wallpaper.mac defaults and may point the
# library at a temporary fixture. Without a guard, a failed or interrupted run
# leaves the user's real preferences and Configuration directory pointing at
# deleted temp paths. This library centralizes that snapshot/restore so the
# logic is fixed in one place instead of copied into ~15 scripts.
#
# Usage:
#   source "$ROOT/scripts/lib/test-state-guard.sh"
#   TEST_ROOT="$(mktemp -d ...)"          # your own temp dir
#   wm_state_guard_init "$TEST_ROOT"      # snapshot before mutating
#   trap wm_state_guard_restore EXIT INT TERM
#   ... run the test ...
#   # wm_state_guard_restore also removes $TEST_ROOT.

WM_STATE_GUARD_DIR="${WM_STATE_GUARD_DIR:-}"
WM_DEFAULTS_BACKUP=""
WM_DEFAULTS_BACKED_UP=0
WM_CONFIG_DIR="$HOME/Library/Application Support/WallpaperMac/Configuration"
WM_CONFIG_BACKUP=""
WM_CONFIG_EXISTED=0

wm_state_guard_init() {
    WM_STATE_GUARD_DIR="$1"
    WM_DEFAULTS_BACKUP="$WM_STATE_GUARD_DIR/defaults.plist"
    WM_CONFIG_BACKUP="$WM_STATE_GUARD_DIR/configuration-backup"
    mkdir -p "$WM_STATE_GUARD_DIR"
    if defaults export com.wallpaper.mac "$WM_DEFAULTS_BACKUP" >/dev/null 2>&1; then
        WM_DEFAULTS_BACKED_UP=1
    else
        rm -f "$WM_DEFAULTS_BACKUP"
        WM_DEFAULTS_BACKED_UP=0
    fi
    if [[ -d "$WM_CONFIG_DIR" ]]; then
        WM_CONFIG_EXISTED=1
        cp -R "$WM_CONFIG_DIR" "$WM_CONFIG_BACKUP" 2>/dev/null || true
    fi
}

wm_state_guard_restore() {
    # Restore defaults from a non-empty backup, otherwise remove only the keys
    # the tests commonly write so a clean machine is not left polluted.
    if (( WM_DEFAULTS_BACKED_UP )) && [[ -s "$WM_DEFAULTS_BACKUP" ]]; then
        defaults delete com.wallpaper.mac >/dev/null 2>&1 || true
        defaults import com.wallpaper.mac "$WM_DEFAULTS_BACKUP" >/dev/null 2>&1 || true
    else
        for key in \
            WallpaperMac.libraryPath \
            WallpaperMac.onboardingCompleted \
            WallpaperMac.pauseInFullScreen \
            WallpaperMac.pauseOnBattery \
            WallpaperMac.fitMode \
            WallpaperMac.loops \
            WallpaperMac.muted \
            WallpaperMac.webWallpaperInteractionEnabled \
            WallpaperMac.storageMode \
            WallpaperMac.autoCheckUpdates; do
            defaults delete com.wallpaper.mac "$key" >/dev/null 2>&1 || true
        done
    fi
    if (( WM_CONFIG_EXISTED )); then
        if [[ -d "$WM_CONFIG_BACKUP" ]]; then
            rm -rf "$WM_CONFIG_DIR"
            cp -R "$WM_CONFIG_BACKUP" "$WM_CONFIG_DIR" 2>/dev/null || true
        fi
    else
        rm -rf "$WM_CONFIG_DIR"
    fi
    # Never leave a durable library path pointing at a temp fixture.
    local temp_root="${TMPDIR:-/tmp}"
    temp_root="${temp_root%/}"
    local current_library
    current_library="$(defaults read com.wallpaper.mac 'WallpaperMac.libraryPath' 2>/dev/null || true)"
    case "$current_library" in
        "$temp_root"/*)
            defaults write com.wallpaper.mac 'WallpaperMac.libraryPath' \
                -string "$HOME/Library/Application Support/WallpaperMac/Library"
            rm -f "$WM_CONFIG_DIR/library-configuration.json"
            ;;
    esac
    [[ -n "$WM_STATE_GUARD_DIR" ]] && rm -rf "$WM_STATE_GUARD_DIR"
}
