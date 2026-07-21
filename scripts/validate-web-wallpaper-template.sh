#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_DIR="$ROOT_DIR/Templates/SimpleWebWallpaper"

required_files=(index.html styles.css script.js README.md)
for file in "${required_files[@]}"; do
  if [[ ! -f "$TEMPLATE_DIR/$file" ]]; then
    echo "缺少模板文件: $file" >&2
    exit 1
  fi
done

if ! grep -q 'href="./styles.css"' "$TEMPLATE_DIR/index.html"; then
  echo "index.html 未使用相对路径加载 styles.css" >&2
  exit 1
fi

if ! grep -q 'src="./script.js"' "$TEMPLATE_DIR/index.html"; then
  echo "index.html 未使用相对路径加载 script.js" >&2
  exit 1
fi

if ! grep -q 'id="clock"' "$TEMPLATE_DIR/index.html"; then
  echo "index.html 缺少时钟元素" >&2
  exit 1
fi

if grep -RInE 'https?://|//cdn\.|unpkg|jsdelivr' "$TEMPLATE_DIR" --include='*.html' --include='*.css' --include='*.js'; then
  echo "模板不应依赖外部网络资源" >&2
  exit 1
fi

if ! grep -q 'window.setInterval(updateClock, 1000)' "$TEMPLATE_DIR/script.js"; then
  echo "script.js 未配置时钟更新" >&2
  exit 1
fi

echo "网页壁纸模板校验通过: $TEMPLATE_DIR"
