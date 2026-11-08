#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wallpapermac-update-smoke-test.XXXXXX")"
SERVER_PID=""
LOCAL_ARTIFACT=""
LOCAL_BACKUP=""
LOCAL_EXISTED=0
trap '[[ -z "$SERVER_PID" ]] || kill "$SERVER_PID" 2>/dev/null || true; if [[ -n "$LOCAL_BACKUP" && -f "$LOCAL_BACKUP" ]]; then cp "$LOCAL_BACKUP" "$LOCAL_ARTIFACT"; elif [[ -n "$LOCAL_ARTIFACT" && "$LOCAL_EXISTED" == 0 ]]; then rm -f "$LOCAL_ARTIFACT"; fi; rm -rf "$TEST_ROOT"' EXIT INT TERM

cd "$ROOT"
VERSION="$(tr -d '[:space:]' < VERSION)"
NAME="WallpaperMac-v${VERSION}-macOS.zip"
SUMS_NAME="WallpaperMac-v${VERSION}-SHA256SUMS.txt"
SIG_NAME="$NAME.sig"
PRIVATE_KEY="${WALLPAPERMAC_UPDATE_SIGNING_KEY:-$ROOT/secrets/WallpaperMac.update.key}"
[[ -f "$PRIVATE_KEY" ]] || { echo 'signing key is required for the local verification fixture' >&2; exit 1; }

printf 'local update fixture\n' > "$TEST_ROOT/$NAME"
HASH="$(shasum -a 256 "$TEST_ROOT/$NAME" | awk '{print $1}')"
printf '%s  %s\n' "$HASH" "$NAME" > "$TEST_ROOT/$SUMS_NAME"
swift scripts/update-signing-tool.swift sign "$TEST_ROOT/$NAME" "$PRIVATE_KEY" >/dev/null

cat > "$TEST_ROOT/server.py" <<'PY'
import http.server, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
version = sys.argv[2]
name = f'WallpaperMac-v{version}-macOS.zip'
sums_name = f'WallpaperMac-v{version}-SHA256SUMS.txt'
sig_name = name + '.sig'
port = int(sys.argv[3])
base = f'http://127.0.0.1:{port}'
assets = [
    {'name': name, 'browser_download_url': base + '/' + name},
    {'name': sums_name, 'browser_download_url': base + '/' + sums_name},
    {'name': sig_name, 'browser_download_url': base + '/' + sig_name},
]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in ('/release.json', '/missing-sig.json', '/bad-hash.json', '/wrong-key.json', '/not-found.json', '/wrong-version.json'):
            selected = list(assets)
            if self.path == '/not-found.json':
                selected[0] = dict(selected[0], browser_download_url=base + '/missing.zip')
            if self.path == '/wrong-version.json':
                old_name = 'WallpaperMac-v0.0.1-macOS.zip'
                selected = [
                    {'name': old_name, 'browser_download_url': base + '/' + old_name},
                    {'name': 'WallpaperMac-v0.0.1-SHA256SUMS.txt', 'browser_download_url': base + '/' + sums_name},
                    {'name': old_name + '.sig', 'browser_download_url': base + '/' + sig_name},
                ]
            if self.path == '/missing-sig.json':
                selected = [a for a in selected if not a['name'].endswith('.sig')]
            body = json.dumps({'tag_name': 'v' + version, 'assets': selected}).encode()
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == '/missing.zip':
            self.send_error(404)
            return
        path = root / self.path.lstrip('/')
        if path.is_file():
            data = path.read_bytes()
            self.send_response(200)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        else:
            self.send_error(404)
    def log_message(self, *args):
        pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
actual_port = server.server_address[1]
base = f'http://127.0.0.1:{actual_port}'
assets = [
    {'name': name, 'browser_download_url': base + '/' + name},
    {'name': sums_name, 'browser_download_url': base + '/' + sums_name},
    {'name': sig_name, 'browser_download_url': base + '/' + sig_name},
]
with open(sys.argv[4], 'w') as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
PY
python3 -I "$TEST_ROOT/server.py" "$TEST_ROOT" "$VERSION" 0 "$TEST_ROOT/port" &
SERVER_PID=$!
for _ in {1..40}; do
    [[ -f "$TEST_ROOT/port" ]] && break
    sleep 0.1
done
PORT="$(cat "$TEST_ROOT/port")"
BASE="http://127.0.0.1:$PORT"

WALLPAPERMAC_UPDATE_API_URL="$BASE/release.json" ./scripts/update-artifact-smoke.sh > "$TEST_ROOT/positive.log"
grep -q 'UPDATE_ARTIFACT_SMOKE_PASSED' "$TEST_ROOT/positive.log"

expect_rejected() {
    local endpoint="$1"
    local output="$2"
    if WALLPAPERMAC_UPDATE_API_URL="$BASE/$endpoint" ./scripts/update-artifact-smoke.sh > "$output" 2>&1; then
        echo "unexpected production success for $endpoint" >&2
        exit 1
    fi
    if grep -q 'UPDATE_ARTIFACT_SMOKE_PASSED' "$output"; then
        echo "failure emitted production PASSED for $endpoint" >&2
        exit 1
    fi
}

expect_rejected missing-sig.json "$TEST_ROOT/missing-sig.log"
printf '%s  %s\n' "$(printf 'different' | shasum -a 256 | awk '{print $1}')" "$NAME" > "$TEST_ROOT/$SUMS_NAME"
expect_rejected bad-hash.json "$TEST_ROOT/bad-hash.log"
printf '%s  %s\n' "$HASH" "$NAME" > "$TEST_ROOT/$SUMS_NAME"

OTHER_KEY="$TEST_ROOT/other.key"
swift scripts/update-signing-tool.swift generate "$OTHER_KEY" >/dev/null
swift scripts/update-signing-tool.swift sign "$TEST_ROOT/$NAME" "$OTHER_KEY" >/dev/null
expect_rejected wrong-key.json "$TEST_ROOT/wrong-key.log"
swift scripts/update-signing-tool.swift sign "$TEST_ROOT/$NAME" "$PRIVATE_KEY" >/dev/null
expect_rejected not-found.json "$TEST_ROOT/not-found.log"
expect_rejected wrong-version.json "$TEST_ROOT/wrong-version.log"

# Explicit diagnostic mode may inspect the local rebuild after a remote 404,
# but it must never print the production success marker.
LOCAL_ARTIFACT="$ROOT/dist/$NAME"
LOCAL_BACKUP="$TEST_ROOT/local-artifact.backup"
if [[ -f "$LOCAL_ARTIFACT" ]]; then
    LOCAL_EXISTED=1
    cp "$LOCAL_ARTIFACT" "$LOCAL_BACKUP"
fi
cp "$TEST_ROOT/$NAME" "$LOCAL_ARTIFACT"
WALLPAPERMAC_UPDATE_API_URL="$BASE/not-found.json" ./scripts/update-artifact-smoke.sh --diagnostic > "$TEST_ROOT/diagnostic.log"
grep -q 'UPDATE_ARTIFACT_SMOKE_DIAGNOSTIC_ONLY' "$TEST_ROOT/diagnostic.log"
if grep -q 'UPDATE_ARTIFACT_SMOKE_PASSED' "$TEST_ROOT/diagnostic.log"; then
    echo 'diagnostic mode emitted production PASSED' >&2
    exit 1
fi

echo 'UPDATE_ARTIFACT_SMOKE_FAILURE_INJECTION_PASSED'
