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

# Consume the already-packaged app; never rebuild it here. Otherwise the DMG
# could come from a different generation than the signed ZIP.
test -x "$APP/Contents/MacOS/WallpaperMac" || {
    print -u2 "Missing packaged app. Run scripts/build-release.sh first."
    exit 1
}
SHORT_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
BUNDLE_VERSION="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")"
[[ "$SHORT_VERSION" == "$VERSION" && "$BUNDLE_VERSION" == "$VERSION" ]] || {
    print -u2 "Packaged app version does not match VERSION: $VERSION"
    exit 1
}
/usr/bin/codesign --verify --deep --strict "$APP"

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
