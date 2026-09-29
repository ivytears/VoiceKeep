#!/usr/bin/env bash
# build-ffmpeg.sh — 源码编译 arm64 原生的静态 ffmpeg / ffprobe，供 build.sh 打进 .app
#
# 用法: ./packaging/build-ffmpeg.sh <macOS 最低版本，如 15.0>
# 输出: 把产物目录打印到 stdout（packaging/cache/ffmpeg-<版本>-arm64-macos<最低版本>/），已存在就直接复用
#
# 为什么不用现成的：evermeet.cx 的预编译包只有 x86_64（目标机没装 Rosetta 一 spawn 就失败，
# 整场转录报错）；brew 的 ffmpeg 挂着 40 多个 brew dylib，搬不走。
# 只用 ffmpeg 自带的原生解码器，已覆盖前端允许上传的 m4a/mp3/wav/aac/ogg/webm/caf/flac；
# 故意不带任何编码器库（server 只输出 pcm wav）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="$SCRIPT_DIR/cache"
MACOS_MIN="${1:?用法: build-ffmpeg.sh <macOS 最低版本>}"

FFMPEG_VERSION="9.0.1"
FFMPEG_SRC_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
# sha256 取自 Homebrew 的 ffmpeg formula
FFMPEG_SRC_SHA256="cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635"

OUT_DIR="$CACHE_DIR/ffmpeg-${FFMPEG_VERSION}-arm64-macos${MACOS_MIN}"
TARBALL="$CACHE_DIR/ffmpeg-${FFMPEG_VERSION}.tar.xz"
SRC_DIR="$CACHE_DIR/ffmpeg-${FFMPEG_VERSION}-src"
BUILD_LOG="$CACHE_DIR/ffmpeg-build.log"

# 日志走 stderr，stdout 只留给最后的产物路径
log() { printf "\033[1;36m[ffmpeg]\033[0m %s\n" "$*" >&2; }
die() { printf "\033[1;31m[ffmpeg]\033[0m %s\n" "$*" >&2; exit 1; }

if [[ -x "$OUT_DIR/ffmpeg" && -x "$OUT_DIR/ffprobe" ]]; then
  log "复用缓存 $OUT_DIR"
  echo "$OUT_DIR"
  exit 0
fi

command -v make  >/dev/null || die "需要 make（来自 Xcode CLT）"
command -v clang >/dev/null || die "需要 clang（来自 Xcode CLT）"
command -v curl  >/dev/null || die "需要 curl"
mkdir -p "$CACHE_DIR"

if [[ ! -f "$TARBALL" ]]; then
  log "下载 ffmpeg $FFMPEG_VERSION 源码"
  curl -fL "$FFMPEG_SRC_URL" -o "$TARBALL.tmp"
  mv "$TARBALL.tmp" "$TARBALL"
fi
if [[ "$(shasum -a 256 "$TARBALL" | awk '{print $1}')" != "$FFMPEG_SRC_SHA256" ]]; then
  rm -f "$TARBALL"
  die "源码包 sha256 不符，已删除（重跑会重新下载）"
fi

log "解压"
rm -rf "$SRC_DIR"
mkdir -p "$SRC_DIR"
tar -xf "$TARBALL" -C "$SRC_DIR" --strip-components=1

log "configure + make（首次约 3–5 分钟，日志: $BUILD_LOG）"
# --disable-autodetect：不自动探测任何外部库（防止链进 brew 的库），产物只依赖系统库；
#   pthreads 不在自动探测名单里但显式打开更稳；zlib 用 SDK 自带的
(
  cd "$SRC_DIR"
  ./configure --disable-autodetect --enable-pthreads --enable-zlib \
    --disable-ffplay --disable-doc --disable-network --disable-debug \
    --extra-cflags="-mmacosx-version-min=$MACOS_MIN" \
    --extra-ldflags="-mmacosx-version-min=$MACOS_MIN" >"$BUILD_LOG" 2>&1
  make -j"$(sysctl -n hw.ncpu)" ffmpeg ffprobe >>"$BUILD_LOG" 2>&1
) || die "编译失败，看日志: $BUILD_LOG"
[[ -x "$SRC_DIR/ffmpeg" && -x "$SRC_DIR/ffprobe" ]] || die "编译完缺产物，看日志: $BUILD_LOG"

mkdir -p "$OUT_DIR"
cp "$SRC_DIR/ffmpeg" "$SRC_DIR/ffprobe" "$OUT_DIR/"
rm -rf "$SRC_DIR"

# 自检：必须是 arm64、不引用 brew 路径
for f in ffmpeg ffprobe; do
  [[ "$(lipo -archs "$OUT_DIR/$f")" == *arm64* ]] || die "$f 不是 arm64"
  otool -L "$OUT_DIR/$f" | grep -q "/opt/homebrew\|/usr/local" && die "$f 仍引用 brew 库"
done

log "完成 $OUT_DIR"
echo "$OUT_DIR"
