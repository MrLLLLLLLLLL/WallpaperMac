#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/WallpaperMac.app"
RESOURCE_DIR="$APP/Contents/Resources"
SOURCE="${WALLPAPERMAC_FFMPEG_SOURCE:-/opt/homebrew/bin/ffmpeg}"

[[ -x "$SOURCE" ]] || {
    print -u2 "ffmpeg source executable not found: $SOURCE"
    exit 1
}

FFMPEG_REAL="$(/usr/bin/stat -f '%Y' "$SOURCE" 2>/dev/null || /usr/bin/readlink -f "$SOURCE")"
if [[ ! -x "$FFMPEG_REAL" ]]; then
    FFMPEG_REAL="$SOURCE"
fi
LIB_ROOT="$RESOURCE_DIR/ffmpeg-libs"
rm -rf "$RESOURCE_DIR/ffmpeg" "$LIB_ROOT"
mkdir -p "$LIB_ROOT"
cp "$FFMPEG_REAL" "$RESOURCE_DIR/ffmpeg"
chmod +x "$RESOURCE_DIR/ffmpeg"

python3 - "$FFMPEG_REAL" "$LIB_ROOT" <<'PY'
import os, pathlib, shutil, subprocess, sys

binary = pathlib.Path(sys.argv[1]).resolve()
lib_root = pathlib.Path(sys.argv[2])
queue = [binary]
seen = set()

def dependencies(path):
    out = subprocess.check_output(["/usr/bin/otool", "-L", str(path)], text=True)
    result = []
    for line in out.splitlines()[1:]:
        dep = line.strip().split(" (", 1)[0].strip()
        if dep:
            result.append(dep)
    return result

copied_by_alias = {}
visited_sources = set()
queue = [binary]

while queue:
    path = queue.pop()
    resolved = path.resolve()
    if resolved in visited_sources:
        continue
    visited_sources.add(resolved)
    for dep in dependencies(path):
        if dep.startswith("/opt/homebrew/") or dep.startswith("/usr/local/"):
            dep_path = pathlib.Path(dep)
            if not dep_path.exists():
                continue
            destination = lib_root / dep_path.name
            if dep not in copied_by_alias:
                shutil.copy2(dep_path, destination)
                destination.chmod(0o755)
                copied_by_alias[dep] = destination
                queue.append(dep_path)

# Rewrite absolute Homebrew dependencies to self-contained @rpath names.
for destination in set(copied_by_alias.values()):
    subprocess.check_call(["/usr/bin/install_name_tool", "-id", f"@rpath/{destination.name}", str(destination)])
    subprocess.check_call(["/usr/bin/install_name_tool", "-add_rpath", "@loader_path", str(destination)])
    for dep in dependencies(destination):
        if dep.startswith("/opt/homebrew/") or dep.startswith("/usr/local/"):
            basename = pathlib.Path(dep).name
            subprocess.check_call([
                "/usr/bin/install_name_tool",
                "-change",
                dep,
                f"@rpath/{basename}",
                str(destination),
            ])

# The bundled ffmpeg resolves all copied libraries from its Resources sibling.
ffmpeg_copy = lib_root.parent / "ffmpeg"
subprocess.check_call([
    "/usr/bin/install_name_tool",
    "-add_rpath",
    "@executable_path/../Resources/ffmpeg-libs",
    str(ffmpeg_copy),
])
for dep in dependencies(ffmpeg_copy):
    if dep.startswith("/opt/homebrew/") or dep.startswith("/usr/local/"):
        basename = pathlib.Path(dep).name
        subprocess.check_call([
            "/usr/bin/install_name_tool",
            "-change",
            dep,
            f"@rpath/{basename}",
            str(ffmpeg_copy),
        ])

PY

if [[ -f "$(dirname "$FFMPEG_REAL")/../LICENSE.md" ]]; then
    cp "$(dirname "$FFMPEG_REAL")/../LICENSE.md" "$RESOURCE_DIR/ffmpeg-LICENSE.md"
fi

# Sign bundled native code before signing the complete app bundle.
/usr/bin/codesign --force --sign - --timestamp=none "$RESOURCE_DIR/ffmpeg"
for dylib in "$LIB_ROOT"/*.dylib; do
    /usr/bin/codesign --force --sign - --timestamp=none "$dylib"
done
