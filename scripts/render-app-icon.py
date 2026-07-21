#!/usr/bin/env python3
"""Render the checked-in SVG logo into a macOS .icns iconset."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SVG = ROOT / "Assets" / "WallpaperMacLogo.svg"
OUTPUT = ROOT / "Assets" / "AppIcon.icns"
CHROME = Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")

if not SVG.is_file():
    raise SystemExit(f"missing logo source: {SVG}")
if not CHROME.is_file():
    raise SystemExit(f"Google Chrome is required to render the icon: {CHROME}")

with tempfile.TemporaryDirectory(prefix="wallpapermac-icon-") as temp:
    temp_path = Path(temp)
    iconset = temp_path / "AppIcon.iconset"
    iconset.mkdir()
    html = temp_path / "render.html"
    html.write_text(
        "<!doctype html><meta charset='utf-8'><style>html,body{margin:0;background:transparent}svg{display:block;width:1024px;height:1024px}</style>"
        + SVG.read_text(),
        encoding="utf-8",
    )
    sizes = [(16, "icon_16x16.png"), (32, "icon_16x16@2x.png"), (32, "icon_32x32.png"),
             (64, "icon_32x32@2x.png"), (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
             (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"), (512, "icon_512x512.png"),
             (1024, "icon_512x512@2x.png")]
    source_png = iconset / "source-1024.png"
    subprocess.run([
        str(CHROME), "--headless", "--disable-gpu", "--hide-scrollbars", "--no-sandbox",
        "--window-size=1024,1024", f"--screenshot={source_png}", f"file://{html}"
    ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for size, filename in sizes:
        output = iconset / filename
        subprocess.run(["/usr/bin/sips", "-z", str(size), str(size), str(source_png), "--out", str(output)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    source_png.unlink()
    if OUTPUT.exists():
        OUTPUT.unlink()
    subprocess.run(["/usr/bin/iconutil", "-c", "icns", str(iconset), "-o", str(OUTPUT)], check=True)

print(f"generated {OUTPUT}")
