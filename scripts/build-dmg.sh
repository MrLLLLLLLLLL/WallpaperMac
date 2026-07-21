#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION_FILE="$ROOT/VERSION"
if [[ ! -f "$VERSION_FILE" ]]; then
    print -u2 "Missing release version file: $VERSION_FILE"
    exit 1
fi
VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    print -u2 "Invalid release version: $VERSION"
    exit 1
fi

APP="$ROOT/dist/WallpaperMac.app"
DMG="$ROOT/dist/WallpaperMac-v${VERSION}-macOS.dmg"
STAGING="$ROOT/.build/dmg-staging"
VOLUME_NAME="WallpaperMac $VERSION"

# Always build the current signed app before creating the installer image.
"$ROOT/scripts/package-release.sh"

rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/WallpaperMac.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
/usr/bin/hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING" \
    -format UDZO \
    -ov \
    -imagekey zlib-level=9 \
    "$DMG" >/dev/null

/usr/bin/hdiutil verify "$DMG" >/dev/null
printf 'DMG: %s\n' "$DMG"
printf 'SHA-256: '
shasum -a 256 "$DMG"
