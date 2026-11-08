#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
APP="$ROOT/dist/WallpaperMac.app"
DMG="$ROOT/dist/WallpaperMac-v${VERSION}-macOS.dmg"
MOUNT_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wallpapermac-release-mount.XXXXXX")"
MOUNT_POINT=""

cleanup() {
    if [[ -n "$MOUNT_POINT" ]]; then
        /usr/bin/hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
    fi
    rm -rf "$MOUNT_ROOT"
}
trap cleanup EXIT INT TERM

[[ -d "$APP" && -f "$DMG" ]] || { echo 'App or DMG is missing' >&2; exit 1; }
/usr/bin/hdiutil attach -readonly -nobrowse -mountroot "$MOUNT_ROOT" "$DMG" > "$MOUNT_ROOT/attach.txt"
MOUNT_POINT="$(awk -F '\t' '$NF ~ /^\// { print $NF }' "$MOUNT_ROOT/attach.txt" | tail -1)"
if [[ -z "$MOUNT_POINT" ]]; then
    MOUNT_POINT="$(find "$MOUNT_ROOT" -maxdepth 1 -type d -name 'WallpaperMac*' -print -quit)"
fi
[[ -d "$MOUNT_POINT/WallpaperMac.app" ]] || { echo 'DMG does not contain WallpaperMac.app' >&2; exit 1; }

# The mounted DMG and the signed App used for the ZIP must be the same frozen
# snapshot, not two successive package-release.sh generations.
diff -qr "$APP" "$MOUNT_POINT/WallpaperMac.app"
/usr/bin/codesign --verify --deep --strict "$MOUNT_POINT/WallpaperMac.app"
printf 'Release App and DMG contents match: %s\n' "$MOUNT_POINT/WallpaperMac.app"
echo 'RELEASE_ARTIFACT_CONSISTENCY_PASSED'
