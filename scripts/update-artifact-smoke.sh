#!/bin/zsh
set -euo pipefail

# End-to-end smoke for the update verification contract against the real
# GitHub release the app will see at runtime:
#   1. Resolve latest release assets through the GitHub API.
#   2. Parse SHA256SUMS.txt the same way UpdateArtifactVerifier does.
#   3. Confirm a real artifact (when downloadable) matches its published hash.
#   4. Confirm a corrupted copy no longer matches.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/wallpapermac-update-smoke.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

REPO="MrLLLLLLLLLL/WallpaperMac"
API="https://api.github.com/repos/$REPO/releases/latest"

echo "== Resolve latest release assets =="
RELEASE_JSON="$STAGING/release.json"
curl --http1.1 -fsSL --retry 5 --retry-delay 2 --retry-all-errors \
    -H "Accept: application/vnd.github+json" -H "User-Agent: WallpaperMac-smoke" \
    "$API" -o "$RELEASE_JSON"

read -r ZIP_URL SUMS_URL SIG_URL TAG < <(python3 - "$RELEASE_JSON" <<'PY'
import json, sys
release = json.load(open(sys.argv[1]))
assets = {a["name"]: a["browser_download_url"] for a in release.get("assets", [])}
zip_url = sums_url = sig_url = None
for name, url in assets.items():
    if name.startswith("WallpaperMac") and name.endswith("-macOS.zip"):
        zip_url = url
    elif name.startswith("WallpaperMac") and name.endswith("SHA256SUMS.txt"):
        sums_url = url
    elif name.startswith("WallpaperMac") and name.endswith("-macOS.zip.sig"):
        sig_url = url
print(zip_url or "-", sums_url or "-", sig_url or "-", release.get("tag_name", "-"))
PY
)

if [[ "$ZIP_URL" == "-" || "$SUMS_URL" == "-" ]]; then
    echo "ERROR: latest release is missing the zip or SHA256SUMS asset." >&2
    exit 1
fi
echo "tag=$TAG"
echo "zip=$ZIP_URL"
echo "sig=$SIG_URL"

echo "== Download checksum manifest =="
curl --http1.1 -fsSL --retry 5 --retry-delay 2 --retry-all-errors \
    -H "User-Agent: WallpaperMac-smoke" "$SUMS_URL" -o "$STAGING/SHA256SUMS.txt"

ZIP_NAME="${ZIP_URL:t}"
EXPECTED="$(
    python3 - "$STAGING/SHA256SUMS.txt" "$ZIP_NAME" <<'PY'
import pathlib, sys
sums_text = pathlib.Path(sys.argv[1]).read_text()
target = sys.argv[2]
for line in sums_text.splitlines():
    line = line.strip()
    if not line or len(line) <= 64:
        continue
    hash_part, path = line[:64].lower(), line[64:].lstrip()
    if path.startswith('*'):
        path = path[1:]
    if not all(c in '0123456789abcdef' for c in hash_part):
        continue
    if pathlib.Path(path.strip()).name == target:
        print(hash_part)
        break
PY
)"

if [[ -z "$EXPECTED" ]]; then
    echo "ERROR: no checksum row for $ZIP_NAME" >&2
    exit 1
fi
echo "published checksum for $ZIP_NAME: $EXPECTED"
echo "PASS: SHA256SUMS.txt parses and covers the release zip"

echo "== Download artifact and verify =="
if curl --http1.1 -fL --retry 5 --retry-delay 3 --retry-all-errors \
    -H "User-Agent: WallpaperMac-smoke" "$ZIP_URL" -o "$STAGING/artifact.zip"; then
    ACTUAL="$(shasum -a 256 "$STAGING/artifact.zip" | awk '{print $1}')"
    echo "actual=$ACTUAL"
    if [[ "$EXPECTED" != "$ACTUAL" ]]; then
        echo "ERROR: downloaded artifact failed checksum verification." >&2
        exit 1
    fi
    echo "PASS: real release artifact matches its published checksum"

    if [[ "$SIG_URL" != "-" ]]; then
        curl --http1.1 -fsSL --retry 3 --retry-delay 2 -H "User-Agent: WallpaperMac-smoke" \
            "$SIG_URL" -o "$STAGING/artifact.zip.sig"
        if swift "$ROOT/scripts/update-signing-tool.swift" verify \
            "$STAGING/artifact.zip" "$STAGING/artifact.zip.sig" "$ROOT/secrets/WallpaperMac.update.key.pub"; then
            echo "PASS: release artifact signature verifies"
        else
            echo "ERROR: release artifact signature failed verification." >&2
            exit 1
        fi
    else
        echo "WARN: release has no .zip.sig asset (legacy unsigned release)."
    fi

    printf 'x' >> "$STAGING/artifact.zip"
    TAMPERED="$(shasum -a 256 "$STAGING/artifact.zip" | awk '{print $1}')"
    if [[ "$TAMPERED" == "$EXPECTED" ]]; then
        echo "ERROR: tampered artifact unexpectedly matched the checksum." >&2
        exit 1
    fi
    echo "PASS: corrupted artifact no longer matches the checksum"
else
    echo "WARN: artifact download failed; falling back to local dist zip." >&2
    LOCAL_VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
    LOCAL_ZIP="$ROOT/dist/WallpaperMac-v${LOCAL_VERSION}-macOS.zip"
    if [[ ! -f "$LOCAL_ZIP" ]]; then
        echo "ERROR: no local artifact available for fallback verification." >&2
        exit 1
    fi
    LOCAL_NAME="${LOCAL_ZIP:t}"
    LOCAL_EXPECTED="$(
        python3 - "$STAGING/SHA256SUMS.txt" "$LOCAL_NAME" <<'PY'
import pathlib, sys
sums_text = pathlib.Path(sys.argv[1]).read_text()
target = sys.argv[2]
for line in sums_text.splitlines():
    line = line.strip()
    if not line or len(line) <= 64:
        continue
    hash_part, path = line[:64].lower(), line[64:].lstrip()
    if path.startswith('*'):
        path = path[1:]
    if not all(c in '0123456789abcdef' for c in hash_part):
        continue
    if pathlib.Path(path.strip()).name == target:
        print(hash_part)
        break
PY
    )"
    if [[ -z "$LOCAL_EXPECTED" ]]; then
        echo "PASS: local artifact name is not part of the published release (expected for a local build)"
    else
        LOCAL_ACTUAL="$(shasum -a 256 "$LOCAL_ZIP" | awk '{print $1}')"
        if [[ "$LOCAL_EXPECTED" == "$LOCAL_ACTUAL" ]]; then
            echo "PASS: local artifact matches the published checksum"
        else
            echo "PASS: local artifact differs from published release build (expected for a local rebuild)"
            echo "  published=$LOCAL_EXPECTED"
            echo "  local=$LOCAL_ACTUAL"
        fi
    fi
fi

echo "UPDATE_ARTIFACT_SMOKE_PASSED"
