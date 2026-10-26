#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/WallpaperMac.app"
BUILD="$ROOT/.build/release/WallpaperMac"
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

cd "$ROOT"
swift build -c release

# Recreate the bundle from scratch so stale files from a previous build cannot
# leak into the deliverable and a clean checkout does not need a pre-existing
# Info.plist under dist/.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$BUILD" "$APP/Contents/MacOS/WallpaperMac"
chmod +x "$APP/Contents/MacOS/WallpaperMac"
"$ROOT/scripts/bundle-ffmpeg.sh"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>WallpaperMac</string>
    <key>CFBundleExecutable</key>
    <string>WallpaperMac</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.wallpaper.mac</string>
    <key>CFBundleName</key>
    <string>WallpaperMac</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

/usr/bin/plutil -lint "$APP/Contents/Info.plist"
SHORT_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
BUNDLE_VERSION="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")"
[[ "$SHORT_VERSION" == "$VERSION" ]] || { print -u2 "CFBundleShortVersionString mismatch: $SHORT_VERSION != $VERSION"; exit 1; }
[[ "$BUNDLE_VERSION" == "$VERSION" ]] || { print -u2 "CFBundleVersion mismatch: $BUNDLE_VERSION != $VERSION"; exit 1; }

# SwiftPM emits a linker-signed executable. Re-sign the complete App Bundle
# after installing Info.plist so the bundle has one coherent ad-hoc signature
# and can be launched by macOS without a stale resource seal.
/usr/bin/codesign --force --sign - --timestamp=none "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"

printf 'Packaged %s (version %s)\n' "$APP" "$VERSION"
