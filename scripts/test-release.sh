#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/WallpaperMac.app"
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
ZIP="$ROOT/dist/WallpaperMac-v${VERSION}-macOS.zip"

cd "$ROOT"
printf '%s\n' '== Web wallpaper template validation =='
./scripts/validate-web-wallpaper-template.sh

printf '%s\n' '== Core behavior tests =='
swift run WallpaperMacCoreTests

printf '%s\n' '== Debug build =='
swift build

printf '%s\n' '== Release build =='
swift build -c release

printf '%s\n' '== App and ZIP packaging =='
./scripts/build-release.sh

printf '%s\n' '== Player runtime matrix =='
./scripts/player-runtime-test.sh

printf '%s\n' '== App smoke test =='
./scripts/smoke-app.sh

printf '%s\n' '== Bundle checks =='
test -x "$APP/Contents/MacOS/WallpaperMac"
test -f "$APP/Contents/Resources/AppIcon.icns"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
SHORT_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
BUNDLE_VERSION="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")"
[[ "$SHORT_VERSION" == "$VERSION" ]] || { print -u2 "CFBundleShortVersionString mismatch: $SHORT_VERSION != $VERSION"; exit 1; }
[[ "$BUNDLE_VERSION" == "$VERSION" ]] || { print -u2 "CFBundleVersion mismatch: $BUNDLE_VERSION != $VERSION"; exit 1; }
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
/usr/bin/file "$APP/Contents/MacOS/WallpaperMac"
test -f "$ZIP"
/usr/bin/unzip -t "$ZIP"

printf '%s\n' '== Source hygiene =='
git diff --check

printf '%s\n' 'ALL_RELEASE_TESTS_PASSED'
