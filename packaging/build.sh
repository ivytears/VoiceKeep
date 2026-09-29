#!/usr/bin/env bash
# build.sh — 把"留声"打包成自包含 .app，再装进 .dmg 方便拷到别的电脑
#
# 用法: ./packaging/build.sh            （SKIP_SMOKE=1 跳过最后的冒烟测试）
# 输出: packaging/dist/留声.app、packaging/dist/留声.dmg
#
# 这个脚本会：
# 1) 源码编译 arm64 原生 ffmpeg / ffprobe（build-ffmpeg.sh，编好缓存到 cache/），下载 mkcert / node 并校验 sha256
# 2) 从 brew 抽取 whisper-cli + 所有 dylib + plugin，做 install_name_tool 重定位
# 3) 复制项目代码 + 模型（不带 .env：留声不调任何云端服务，安装包里不该有密钥），
#    写启动脚本 / Info.plist / 图标
# 4) 清隔离标记、ad-hoc 签名、可移植性检查、打 DMG、跑 launcher-test.sh + smoke-test.sh
#
# 目标机要求：Apple Silicon，macOS 不低于 brew whisper-cli 的 minos（构建时自动写进 Info.plist）

set -euo pipefail

# ---------- 路径 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CACHE_DIR="$SCRIPT_DIR/cache"
DIST_DIR="$SCRIPT_DIR/dist"
APP_NAME="留声"
APP="$DIST_DIR/${APP_NAME}.app"
DMG="$DIST_DIR/${APP_NAME}.dmg"
CONTENTS="$APP/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"
BIN_DIR="$RES_DIR/bin"
LIB_DIR="$RES_DIR/lib"
APP_DIR="$RES_DIR/app"
MODELS_DIR="$RES_DIR/models"

BREW_PREFIX="/opt/homebrew"
# opt/ggml 是指向当前已装版本的软链，不写死版本号
GGML_LIBEXEC="$BREW_PREFIX/opt/ggml/libexec"

# 上游二进制（首次构建会下载到 cache/）。sha256 防半截文件，也防网盘转存来的来路不明文件
MKCERT_URL="https://github.com/FiloSottile/mkcert/releases/download/v1.4.4/mkcert-v1.4.4-darwin-arm64"
MKCERT_SHA256="c8af0df44bce04359794dad8ea28d750437411d632748049d08644ffb66a60c6"
# 官方 Node.js LTS（静态链接版本，只依赖系统库）。brew 的 node 25+ 已变成 wrapper + 一堆 dylib，不可移植。
NODE_VERSION="v22.18.0"
NODE_URL="https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-darwin-arm64.tar.gz"
NODE_SHA256="2c12913cba67af77ded8a399df3fd91c2e7f8628c7079da40bb9ff33bf00dfc0"

log() { printf "\033[1;36m[build]\033[0m %s\n" "$*"; }
die() { printf "\033[1;31m[build]\033[0m %s\n" "$*" >&2; exit 1; }
# Mach-O 的最低系统版本（LC_BUILD_VERSION 的 minos）
minos_of() { otool -l "$1" | awk '/LC_BUILD_VERSION/{f=1} f && $1=="minos" && !done {print $2; done=1}'; }
sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
# 下载到 cache（已有就复用）并校验 sha256；不符就删掉，下次重下
ensure_cached() {
  local url="$1" out="$2" sha="$3"
  if [[ ! -f "$out" ]]; then
    log "下载 $(basename "$out")"
    curl -fL "$url" -o "$out.tmp"
    mv "$out.tmp" "$out"
  fi
  if [[ "$(sha256_of "$out")" != "$sha" ]]; then
    rm -f "$out"
    die "$(basename "$out") sha256 不符，已删除（重跑会重新下载）"
  fi
}

# ---------- 0. 前置检查 ----------
[[ "$(uname -s)" == "Darwin" ]]      || die "只支持 macOS"
[[ "$(uname -m)" == "arm64" ]]       || die "目前只支持 Apple Silicon（arm64）"
command -v install_name_tool >/dev/null || die "需要 install_name_tool（来自 Xcode CLT）"
command -v codesign          >/dev/null || die "需要 codesign（来自 Xcode CLT）"
command -v curl              >/dev/null || die "需要 curl"

[[ -d "$GGML_LIBEXEC" ]] || die "缺 brew 的 ggml plugin: $GGML_LIBEXEC（请 brew install ggml）"
[[ -x "$BREW_PREFIX/bin/whisper-cli" ]] || die "缺 brew 的 whisper-cli（请 brew install whisper-cpp）"
[[ -f ~/.whisper-models/ggml-large-v3-turbo-q8_0.bin && -f ~/.whisper-models/ggml-silero-v5.1.2.bin ]] \
  || die "缺模型 ~/.whisper-models/ggml-large-v3-turbo-q8_0.bin / ggml-silero-v5.1.2.bin（huggingface.co/ggerganov/whisper.cpp 官方仓库）"
[[ -f "$HOME/.diar-models/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx" \
   && -f "$HOME/.diar-models/sherpa-onnx-pyannote-segmentation-3-0/model.onnx" ]] \
  || die "缺说话人分离模型 ~/.diar-models（k2-fsa/sherpa-onnx 官方 release，见 tools/diarize.py 头注）"

# whisper/ggml 直接取自 brew bottle，它们的 minos 就是整个 .app 的最低系统要求
MACOS_MIN="$(minos_of "$BREW_PREFIX/bin/whisper-cli")"
[[ -n "$MACOS_MIN" ]] || die "读不到 whisper-cli 的最低系统版本（otool 无 LC_BUILD_VERSION）"

mkdir -p "$CACHE_DIR" "$DIST_DIR"

# ---------- 1. 清理旧产物 ----------
log "清理旧 .app"
rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$BIN_DIR" "$LIB_DIR" "$APP_DIR" "$MODELS_DIR" "$CONTENTS/Frameworks"

# ---------- 2. ffmpeg / ffprobe（源码编译）+ mkcert + node ----------
log "准备 arm64 原生 ffmpeg / ffprobe（见 build-ffmpeg.sh）"
FFMPEG_BUILT="$("$SCRIPT_DIR/build-ffmpeg.sh" "$MACOS_MIN")"
cp "$FFMPEG_BUILT/ffmpeg"  "$BIN_DIR/ffmpeg"
cp "$FFMPEG_BUILT/ffprobe" "$BIN_DIR/ffprobe"

ensure_cached "$MKCERT_URL" "$CACHE_DIR/mkcert" "$MKCERT_SHA256"
cp "$CACHE_DIR/mkcert" "$BIN_DIR/mkcert"

log "解压官方 Node.js"
ensure_cached "$NODE_URL" "$CACHE_DIR/node.tar.gz" "$NODE_SHA256"
NODE_EXTRACT="$CACHE_DIR/node-extracted"
rm -rf "$NODE_EXTRACT"
mkdir -p "$NODE_EXTRACT"
tar -xzf "$CACHE_DIR/node.tar.gz" -C "$NODE_EXTRACT" --strip-components=1
cp "$NODE_EXTRACT/bin/node" "$BIN_DIR/node"

chmod +x "$BIN_DIR/ffmpeg" "$BIN_DIR/ffprobe" "$BIN_DIR/mkcert" "$BIN_DIR/node"

# ---------- 3. 抽取 whisper-cli + 重定位 dylib ----------
log "复制 whisper-cli + plugin .so（必须和 whisper-cli 同目录）"
cp "$BREW_PREFIX/bin/whisper-cli" "$BIN_DIR/whisper-cli"
cp "$GGML_LIBEXEC"/libggml-*.so   "$BIN_DIR/"

log "复制 dylib 到 Resources/lib（rpath = @loader_path/../lib）"
cp "$BREW_PREFIX/lib/libwhisper.1.dylib"                  "$LIB_DIR/"
cp "$BREW_PREFIX/opt/ggml/lib/libggml.0.dylib"            "$LIB_DIR/"
cp "$BREW_PREFIX/opt/ggml/lib/libggml-base.0.dylib"       "$LIB_DIR/"
cp "$BREW_PREFIX/opt/libomp/lib/libomp.dylib"             "$LIB_DIR/"

chmod u+w "$BIN_DIR/whisper-cli" "$BIN_DIR"/libggml-*.so "$LIB_DIR"/*.dylib

log "改 install name（让 dylib 自己声明的路径变成 @rpath）"
install_name_tool -id "@rpath/libwhisper.1.dylib"     "$LIB_DIR/libwhisper.1.dylib"
install_name_tool -id "@rpath/libggml.0.dylib"        "$LIB_DIR/libggml.0.dylib"
install_name_tool -id "@rpath/libggml-base.0.dylib"   "$LIB_DIR/libggml-base.0.dylib"
install_name_tool -id "@rpath/libomp.dylib"           "$LIB_DIR/libomp.dylib"

log "改 whisper-cli 对 ggml 的绝对引用 → @rpath"
install_name_tool -change "$BREW_PREFIX/opt/ggml/lib/libggml.0.dylib"      "@rpath/libggml.0.dylib"      "$BIN_DIR/whisper-cli"
install_name_tool -change "$BREW_PREFIX/opt/ggml/lib/libggml-base.0.dylib" "@rpath/libggml-base.0.dylib" "$BIN_DIR/whisper-cli"

log "改 libwhisper.dylib 内部对 ggml 的绝对引用 → @rpath"
install_name_tool -change "$BREW_PREFIX/opt/ggml/lib/libggml.0.dylib"      "@rpath/libggml.0.dylib"      "$LIB_DIR/libwhisper.1.dylib"
install_name_tool -change "$BREW_PREFIX/opt/ggml/lib/libggml-base.0.dylib" "@rpath/libggml-base.0.dylib" "$LIB_DIR/libwhisper.1.dylib"

log "改 cpu-apple plugin 对 libomp 的绝对引用 → @rpath"
for so in "$BIN_DIR"/libggml-cpu-apple_*.so; do
  install_name_tool -change "$BREW_PREFIX/opt/libomp/lib/libomp.dylib" "@rpath/libomp.dylib" "$so"
done

# plugin .so 也要能找 lib/ 下的 libggml-base，加 rpath（whisper-cli 同目录 → ../lib）
for so in "$BIN_DIR"/libggml-*.so; do
  install_name_tool -add_rpath "@loader_path/../lib" "$so" 2>/dev/null || true
done

# ---------- 4. 项目代码 + 模型 ----------
log "复制项目代码"
cp "$PROJECT_ROOT/server.js"       "$APP_DIR/"
cp -r "$PROJECT_ROOT/public"       "$APP_DIR/"
cp -r "$PROJECT_ROOT/node_modules" "$APP_DIR/"
cp "$PROJECT_ROOT/package.json"    "$APP_DIR/"
cp "$PROJECT_ROOT/LICENSE" "$PROJECT_ROOT/THIRD_PARTY_NOTICES.md" "$RES_DIR/"
mkdir -p "$APP_DIR/tools"
cp "$PROJECT_ROOT/tools/speakers.js" "$PROJECT_ROOT/tools/textclean.js" "$PROJECT_ROOT/tools/corrections.js" \
   "$PROJECT_ROOT/tools/diarize.py" "$APP_DIR/tools/"

log "复制模型"
cp ~/.whisper-models/ggml-large-v3-turbo-q8_0.bin "$MODELS_DIR/"   # q8_0：2026-09-20 起换掉 q5_0，准确率优先
cp ~/.whisper-models/ggml-silero-v5.1.2.bin       "$MODELS_DIR/"

log "复制说话人分离模型（34MB；跑分离还需要 ~/.diar-venv，launcher 会自动探测，没有就只出纯文字）"
mkdir -p "$RES_DIR/diar-models/sherpa-onnx-pyannote-segmentation-3-0"
cp "$HOME/.diar-models/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx" "$RES_DIR/diar-models/"
cp "$HOME/.diar-models/sherpa-onnx-pyannote-segmentation-3-0/model.onnx"   "$RES_DIR/diar-models/sherpa-onnx-pyannote-segmentation-3-0/"

# ---------- 5. 启动脚本 + Info.plist + 图标 ----------
log "写启动脚本"
cp "$SCRIPT_DIR/launcher.sh" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

log "写 Info.plist（最低系统版本 = whisper-cli 的 minos $MACOS_MIN）"
cp "$SCRIPT_DIR/Info.plist" "$CONTENTS/Info.plist"
plutil -replace LSMinimumSystemVersion -string "$MACOS_MIN" "$CONTENTS/Info.plist"

# 图标由 make-icon.sh 生成；没有就用系统默认图标
if [[ -f "$SCRIPT_DIR/AppIcon.icns" ]]; then
  cp "$SCRIPT_DIR/AppIcon.icns" "$RES_DIR/AppIcon.icns"
else
  log "没有 packaging/AppIcon.icns（跑 ./packaging/make-icon.sh 生成），用默认图标"
fi

# ---------- 6. 清隔离标记 + 签名 ----------
# cache 里从网盘 / 浏览器来的文件带 com.apple.quarantine，进了包一执行就被 Gatekeeper SIGKILL
log "清掉包内所有文件的隔离标记"
xattr -cr "$APP"

log "ad-hoc 签名（install_name_tool 之后必须重签；先逐个签二进制 / dylib / plugin，再签整个 .app）"
for f in "$BIN_DIR"/* "$LIB_DIR"/*; do
  codesign -f -s - "$f"
done
codesign -f -s - --deep "$APP"
codesign --verify --deep --strict "$APP" || die "签名校验失败（拷到目标机会被报「已损坏」）"

# ---------- 7. 可移植性检查 ----------
# 构建机自己装着 brew 和 Rosetta，漏打包的依赖在本机跑不出错，只能静态查
log "可移植性检查：每个二进制都要含 arm64，且不引用 brew 路径"
for f in "$BIN_DIR"/* "$LIB_DIR"/*; do
  name="$(basename "$f")"
  archs="$(lipo -archs "$f")"
  [[ " $archs " == *" arm64 "* ]] || die "$name 不是 arm64（$archs）：目标机没装 Rosetta 就跑不起来"
  links="$(otool -L "$f" | tail -n +2)$(otool -l "$f" | grep -A2 LC_RPATH || true)"
  [[ "$links" != *"$BREW_PREFIX"* ]] || die "$name 仍引用 brew 路径（目标机没有 brew 就找不到库）:
$links"
done

# ---------- 8. 打 DMG ----------
log "打 DMG"
DMG_STAGE="$DIST_DIR/dmg-stage"
rm -rf "$DMG_STAGE" "$DMG"
mkdir -p "$DMG_STAGE"
ditto "$APP" "$DMG_STAGE/${APP_NAME}.app"
ln -s /Applications "$DMG_STAGE/Applications"
sed "s/__MACOS_MIN__/$MACOS_MIN/g" "$SCRIPT_DIR/安装说明.txt" >"$DMG_STAGE/安装说明.txt"
cp "$PROJECT_ROOT/LICENSE" "$DMG_STAGE/LICENSE.txt"
cp "$PROJECT_ROOT/THIRD_PARTY_NOTICES.md" "$DMG_STAGE/第三方组件与许可证.md"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGE" -format UDZO -ov "$DMG" >/dev/null
rm -rf "$DMG_STAGE"

# ---------- 9. 冒烟测试 ----------
if [[ "${SKIP_SMOKE:-}" == "1" ]]; then
  log "SKIP_SMOKE=1，跳过冒烟测试"
else
  "$SCRIPT_DIR/launcher-test.sh" "$APP"   # 几秒就跑完，放前面
  "$SCRIPT_DIR/smoke-test.sh" "$APP"
fi

# ---------- 10. 产物报告 ----------
log "完成 ✓"
du -sh "$APP" "$DMG"
echo "DMG sha256: $(sha256_of "$DMG")"
echo ""
echo "目标机要求: Apple Silicon + macOS $MACOS_MIN 或更新"
echo "下一步: 把 $DMG 拷到目标电脑 → 双击打开 → 按里面的「安装说明.txt」操作"
