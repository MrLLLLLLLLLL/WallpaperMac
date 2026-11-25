#!/bin/zsh
# Publishes the current VERSION as a GitHub release and immediately verifies
# the live artifacts. Run only after test-release.sh passes and the release
# commit is on main. Idempotent for re-runs: if the tag or release already
# exists it fails fast instead of creating a duplicate.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(tr -d '[:space:]' < VERSION)"
if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    print -u2 "Invalid VERSION: $VERSION"
    exit 1
fi

ZIP="dist/WallpaperMac-v${VERSION}-macOS.zip"
DMG="dist/WallpaperMac-v${VERSION}-macOS.dmg"
SUMS="dist/WallpaperMac-v${VERSION}-SHA256SUMS.txt"
NOTES="docs/release-notes/${VERSION}.md"
PUBLIC_KEY="${WALLPAPERMAC_UPDATE_SIGNING_PUBLIC_KEY:-$ROOT/secrets/WallpaperMac.update.key.pub}"

for f in "$ZIP" "$ZIP.sig" "$DMG" "$SUMS"; do
    [[ -f "$f" ]] || { print -u2 "Missing release artifact: $f (run build-release.sh first)"; exit 1; }
done
[[ -f "$NOTES" ]] || { print -u2 "Missing release notes: $NOTES"; exit 1; }
command -v gh >/dev/null || { print -u2 "gh CLI is required"; exit 1; }

if [[ "${1:-}" != "--yes" ]]; then
    print -u2 "This will tag v$VERSION, push it, create a GitHub release, and verify the live artifacts."
    print -u2 "Re-run with --yes to proceed."
    exit 2
fi

# Verify the local artifacts once more before publishing.
swift scripts/update-signing-tool.swift verify "$ZIP" "$ZIP.sig" "$PUBLIC_KEY"

if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
    print -u2 "Tag v$VERSION already exists."
    exit 1
fi

printf '%s\n' "== Tagging v$VERSION =="
git tag -a "v$VERSION" -m "WallpaperMac $VERSION"
git push origin "v$VERSION"

printf '%s\n' "== Creating GitHub release =="
gh release create "v$VERSION" \
    --title "WallpaperMac $VERSION" \
    --notes-file "$NOTES" \
    "$DMG" "$ZIP" "$ZIP.sig" "$SUMS"

printf '%s\n' '== Verifying live artifacts (production smoke) =='
./scripts/update-artifact-smoke.sh

printf '%s\n' "PUBLISH_RELEASE_PASSED v$VERSION"
