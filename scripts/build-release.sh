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
find "$ROOT/dist" -maxdepth 1 -type f \( \
    -name 'WallpaperMac-v*-macOS.zip' -o \
    -name 'WallpaperMac-v*-macOS.zip.sig' -o \
    -name 'WallpaperMac-v*-SHA256SUMS.txt' \
\) -delete
(cd "$ROOT/dist" && zip -r -X "$ZIP" WallpaperMac.app >/dev/null)
/usr/bin/unzip -t "$ZIP" >/dev/null

SHORT_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
BUNDLE_VERSION="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")"
[[ "$SHORT_VERSION" == "$VERSION" ]] || { print -u2 "Release app version mismatch: $SHORT_VERSION != $VERSION"; exit 1; }
[[ "$BUNDLE_VERSION" == "$VERSION" ]] || { print -u2 "Release build version mismatch: $BUNDLE_VERSION != $VERSION"; exit 1; }

printf 'Release archive: %s\n' "$ZIP"
printf 'SHA-256: '
shasum -a 256 "$ZIP"

# Detached Ed25519 signature for in-app update verification. The private key
# never lives in the repository. Release builds fail closed without it: an
# unsigned zip would be rejected by update clients with signaturePolicy
# .required. Contributors can opt into unsigned dev packages explicitly.
SIGNING_KEY="${WALLPAPERMAC_UPDATE_SIGNING_KEY:-$ROOT/secrets/WallpaperMac.update.key}"
if [[ -f "$SIGNING_KEY" ]]; then
    rm -f "$ZIP.sig"
    swift "$ROOT/scripts/update-signing-tool.swift" sign "$ZIP" "$SIGNING_KEY"
    printf 'Signature: %s.sig\n' "$ZIP"
elif [[ "${WALLPAPERMAC_ALLOW_UNSIGNED:-0}" == "1" ]]; then
    print -u2 "Warning: signing key not found; producing UNSIGNED dev package."
else
    print -u2 "ERROR: signing key not found at $SIGNING_KEY."
    print -u2 "Set WALLPAPERMAC_UPDATE_SIGNING_KEY, or WALLPAPERMAC_ALLOW_UNSIGNED=1 for a dev-only unsigned package."
    exit 1
fi

# Publishable checksum manifest: one row per release artifact present in dist/.
SUMS="$ROOT/dist/WallpaperMac-v${VERSION}-SHA256SUMS.txt"
{
    for artifact in "$ZIP" "$ROOT/dist/WallpaperMac-v${VERSION}-macOS.dmg"; do
        if [[ -f "$artifact" ]]; then
            shasum -a 256 "$artifact" | sed "s|${ROOT}/||"
        fi
    done
} > "$SUMS"
printf 'Checksums: %s\n' "$SUMS"
cat "$SUMS"
