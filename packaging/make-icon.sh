#!/usr/bin/env bash
# make-icon.sh — 用 AppKit 画出 留声 的应用图标并生成 AppIcon.icns（build.sh 自动打进 .app）
#
# 用法: ./packaging/make-icon.sh      （需要 Xcode CLT 的 clang）
# 输出: packaging/AppIcon.icns

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/liusheng-icon.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

command -v clang    >/dev/null || { echo "需要 clang（xcode-select --install）" >&2; exit 1; }
command -v iconutil >/dev/null || { echo "需要 iconutil" >&2; exit 1; }

clang -fobjc-arc -Wall -framework AppKit -o "$WORK/AppIcon" "$SCRIPT_DIR/AppIcon.m"
"$WORK/AppIcon" "$WORK/icon-1024.png"

# iconset 要求的固定文件名：icon_<n>x<n>.png 与 @2x
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for n in 16 32 128 256 512; do
  sips -z "$n" "$n" "$WORK/icon-1024.png" --out "$ICONSET/icon_${n}x${n}.png" >/dev/null
  sips -z "$((n * 2))" "$((n * 2))" "$WORK/icon-1024.png" --out "$ICONSET/icon_${n}x${n}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$SCRIPT_DIR/AppIcon.icns"
echo "生成 $SCRIPT_DIR/AppIcon.icns"
