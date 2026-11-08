#!/bin/zsh
set -euo pipefail

# Production mode verifies the real release contract used by clients. An
# explicit --diagnostic mode may inspect a local rebuild after a network
# failure, but never reports that diagnostic as a passing production check.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/wallpapermac-update-smoke.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

DIAGNOSTIC=0
if [[ "${1:-}" == "--diagnostic" ]]; then
    DIAGNOSTIC=1
elif [[ $# -gt 0 ]]; then
    echo "usage: $0 [--diagnostic]" >&2
    exit 2
fi

REPO="MrLLLLLLLLLL/WallpaperMac"
API="${WALLPAPERMAC_UPDATE_API_URL:-https://api.github.com/repos/$REPO/releases/latest}"

echo "== Resolve latest release assets =="
RELEASE_JSON="$STAGING/release.json"
curl --http1.1 -fsSL --connect-timeout 15 --max-time 120 \
    --retry 5 --retry-delay 2 --retry-all-errors \
    -H "Accept: application/vnd.github+json" -H "User-Agent: WallpaperMac-smoke" \
    "$API" -o "$RELEASE_JSON"

read -r ZIP_URL SUMS_URL SIG_URL TAG < <(python3 - "$RELEASE_JSON" <<'PY'
import json, re, sys
release = json.load(open(sys.argv[1]))
tag = release.get("tag_name", "")
version = tag[1:] if tag[:1] in ("v", "V") else tag
if not re.fullmatch(r"\d+\.\d+\.\d+", version):
    raise SystemExit("release tag is not a major.minor.patch version")
assets = {a["name"]: a["browser_download_url"] for a in release.get("assets", [])}
zip_name = f"WallpaperMac-v{version}-macOS.zip"
sums_name = f"WallpaperMac-v{version}-SHA256SUMS.txt"
sig_name = zip_name + ".sig"
# Only the exact assets for this release tag are valid. Older assets in the
# same release must not make this check pass for a version clients reject.
print(assets.get(zip_name) or "-", assets.get(sums_name) or "-", assets.get(sig_name) or "-", tag or "-")
PY
)

if [[ "$ZIP_URL" == "-" || "$SUMS_URL" == "-" ]]; then
    echo "ERROR: latest release is missing the zip or SHA256SUMS asset." >&2
    exit 1
fi
if [[ "$SIG_URL" == "-" && "$DIAGNOSTIC" == 0 ]]; then
    echo "ERROR: latest release is missing the required .zip.sig asset." >&2
    exit 1
fi
echo "tag=$TAG"
echo "zip=$ZIP_URL"
echo "sig=$SIG_URL"

echo "== Download checksum manifest =="
curl --http1.1 -fsSL --connect-timeout 15 --max-time 120 \
    --retry 5 --retry-delay 2 --retry-all-errors \
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
if [[ -z "$EXPECTED" && "$DIAGNOSTIC" == 0 ]]; then
    echo "ERROR: no checksum row for $ZIP_NAME" >&2
    exit 1
fi
if [[ -n "$EXPECTED" ]]; then
    echo "published checksum for $ZIP_NAME: $EXPECTED"
    echo "PASS: SHA256SUMS.txt parses and covers the release zip"
else
    echo "WARN: no checksum row for $ZIP_NAME; diagnostic mode cannot validate it."
fi

echo "== Download artifact and verify =="
# Bounded so a stalled transfer (seen on flaky links) fails over to the local
# artifact check instead of hanging the smoke run forever. Attempts resume
# from the partial file, and a transfer under 4 KB/s for a minute counts as
# stalled; together these let a slow-but-alive link finish across retries.
if curl --http1.1 -fL -C - --connect-timeout 15 --max-time 300 \
    --speed-limit 4096 --speed-time 60 \
    --retry 2 --retry-delay 3 --retry-all-errors \
    -H "User-Agent: WallpaperMac-smoke" "$ZIP_URL" -o "$STAGING/artifact.zip"; then
    ACTUAL="$(shasum -a 256 "$STAGING/artifact.zip" | awk '{print $1}')"
    echo "actual=$ACTUAL"
    if [[ -n "$EXPECTED" ]]; then
        if [[ "$EXPECTED" != "$ACTUAL" ]]; then
            echo "ERROR: downloaded artifact failed checksum verification." >&2
            exit 1
        fi
        echo "PASS: real release artifact matches its published checksum"
    else
        echo "WARN: downloaded artifact has no checksum row; diagnostic mode cannot validate its hash."
    fi

    # Verify against the public key embedded in the shipping app, not a
    # different local key file that could silently drift from it.
    python3 - "$ROOT/Sources/WallpaperMacCore/Update/UpdateSignature.swift" "$STAGING/embedded.pub" <<'PY'
import pathlib, re, sys
source = pathlib.Path(sys.argv[1]).read_text()
match = re.search(r'releasePublicKeyBase64\s*=\s*"([^"]+)"', source)
if not match:
    raise SystemExit('embedded release public key not found')
pathlib.Path(sys.argv[2]).write_text(match.group(1) + '\n')
PY
    if [[ "$SIG_URL" == "-" ]]; then
        echo "WARN: release has no .zip.sig asset; diagnostic mode only."
    else
        curl --http1.1 -fsSL --connect-timeout 15 --max-time 120 \
            --retry 3 --retry-delay 2 -H "User-Agent: WallpaperMac-smoke" \
            "$SIG_URL" -o "$STAGING/artifact.zip.sig"
        if swift "$ROOT/scripts/update-signing-tool.swift" verify \
            "$STAGING/artifact.zip" "$STAGING/artifact.zip.sig" "$STAGING/embedded.pub"; then
            echo "PASS: release artifact signature verifies against the embedded public key"
        else
            echo "ERROR: release artifact signature failed verification." >&2
            exit 1
        fi
    fi

    if [[ -n "$EXPECTED" ]]; then
        printf 'x' >> "$STAGING/artifact.zip"
        TAMPERED="$(shasum -a 256 "$STAGING/artifact.zip" | awk '{print $1}')"
        if [[ "$TAMPERED" == "$EXPECTED" ]]; then
            echo "ERROR: tampered artifact unexpectedly matched the checksum." >&2
            exit 1
        fi
        echo "PASS: corrupted artifact no longer matches the checksum"
    fi
else
    if [[ "$DIAGNOSTIC" == 0 ]]; then
        echo "ERROR: release artifact download failed; production verification is not complete." >&2
        exit 1
    fi
    echo "WARN: artifact download failed; entering explicit local diagnostic mode." >&2
    LOCAL_VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
    LOCAL_ZIP="$ROOT/dist/WallpaperMac-v${LOCAL_VERSION}-macOS.zip"
    if [[ ! -f "$LOCAL_ZIP" ]]; then
        echo "ERROR: no local artifact available for diagnostic comparison." >&2
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
        echo "WARN: local artifact name is not part of the published release."
    else
        LOCAL_ACTUAL="$(shasum -a 256 "$LOCAL_ZIP" | awk '{print $1}')"
        if [[ "$LOCAL_EXPECTED" != "$LOCAL_ACTUAL" ]]; then
            echo "ERROR: local artifact differs from the published checksum." >&2
            exit 1
        fi
        echo "Diagnostic: local artifact matches the published checksum"
    fi
fi

if [[ "$DIAGNOSTIC" == 1 ]]; then
    echo "UPDATE_ARTIFACT_SMOKE_DIAGNOSTIC_ONLY"
else
    echo "UPDATE_ARTIFACT_SMOKE_PASSED"
fi
