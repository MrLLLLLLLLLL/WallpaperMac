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

"$ROOT/scripts/validate-web-wallpaper-template.sh"
"$ROOT/scripts/package-release.sh"

APP="$ROOT/dist/WallpaperMac.app"
ZIP="$ROOT/dist/WallpaperMac-v${VERSION}-macOS.zip"
find "$ROOT/dist" -maxdepth 1 -type f -name 'WallpaperMac-v*-macOS.zip' -delete
(cd "$ROOT/dist" && zip -r -X "$ZIP" WallpaperMac.app >/dev/null)
/usr/bin/unzip -t "$ZIP" >/dev/null

SHORT_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
BUNDLE_VERSION="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")"
[[ "$SHORT_VERSION" == "$VERSION" ]] || { print -u2 "Release app version mismatch: $SHORT_VERSION != $VERSION"; exit 1; }
[[ "$BUNDLE_VERSION" == "$VERSION" ]] || { print -u2 "Release build version mismatch: $BUNDLE_VERSION != $VERSION"; exit 1; }

printf 'Release archive: %s\n' "$ZIP"
printf 'SHA-256: '
shasum -a 256 "$ZIP"
