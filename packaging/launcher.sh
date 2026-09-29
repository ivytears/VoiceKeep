#!/usr/bin/env bash
# 留声 .app 启动脚本（Contents/MacOS/留声）
#
# 职责：
# 1) 解析 .app 内的资源路径
# 2) 去掉下载 / AirDrop / 网盘带来的隔离标记（否则内置二进制一执行就被 Gatekeeper 杀掉）
# 3) 每次双击都以当前用户身份检查 HTTPS 证书：SAN 含本机 .local 名和所有局域网 IP，IP 变了就重签
#    （server 只听本机，局域网 IP 用不上但无害）。服务已经在跑也照样重签，server.js 会热加载新证书，不重启、不打断转录
# 4) 首次启动：以当前用户身份把本地 CA 加进登录钥匙串信任，macOS 弹一次密码框（只一次）
# 5) 已在运行 → 只打开浏览器（重复双击不会起第二个 server 撞端口）
# 6) 否则注入环境变量（PATH、模型路径、证书路径、数据目录），启动 server.js，端口就绪后打开浏览器
# 7) server（node）在后台常驻，启动程序开完浏览器就退出——.app 进程不能一直占着，否则再双击打不开网页
#    （见启动段注释）；Info.plist 设了 LSUIElement，不占 Dock；退出留声 = 结束 node 进程
#
# 从终端调试时可用的环境变量（Finder 启动时环境干净，全走默认值）：
#   LIUSHENG_DATA_ROOT  数据根目录（默认 ~/Library/Application Support/留声）
#   PORT / HTTPS_PORT   端口（默认 3000 / 3443）
#   LIUSHENG_NO_OPEN=1  不自动打开浏览器

set -euo pipefail

# ---------- 路径 ----------
# 形如 /Applications/留声.app/Contents/MacOS/留声 → 取上两层
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTENTS="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_BUNDLE="$(cd "$CONTENTS/.." && pwd)"
RES="$CONTENTS/Resources"
BIN="$RES/bin"
APP_CODE="$RES/app"
MODELS="$RES/models"

# 内置程序放最前，别被系统或 brew 的同名程序抢；Finder 启动时 PATH 本来就只有系统目录
export PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin"

# 用户可写数据目录（沙盒外，但符合 macOS 惯例）
USER_DATA_DIR="${LIUSHENG_DATA_ROOT:-$HOME/Library/Application Support/留声}"
# 从曾用名「开会宝」迁回已有数据（证书/转录），避免改名后丢失、需重新安装证书
OLD_DATA_DIR="$HOME/Library/Application Support/开会宝"
if [[ -d "$OLD_DATA_DIR" && ! -d "$USER_DATA_DIR" ]]; then
  mv "$OLD_DATA_DIR" "$USER_DATA_DIR" 2>/dev/null || true
fi
CERTS_DIR="$USER_DATA_DIR/certs"
DATA_DIR="$USER_DATA_DIR/data"
LOG_DIR="$HOME/Library/Logs/留声"
LOG_FILE="$LOG_DIR/server.log"
# CAROOT 指到用户目录，不碰系统 mkcert 的状态
export CAROOT="$CERTS_DIR/CAROOT"
CA_INSTALLED_MARK="$CERTS_DIR/.ca-installed"   # CA 已被信任（信任过就不再要密码）
SANS_FILE="$CERTS_DIR/sans.txt"                # 当前证书覆盖的名字 / IP

export PORT="${PORT:-3000}"
export HTTPS_PORT="${HTTPS_PORT:-3443}"
URL="https://localhost:$HTTPS_PORT"

mkdir -p "$CAROOT" "$DATA_DIR" "$LOG_DIR"
log() { printf '[launcher %s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"; }

# ---------- 提示框工具（osascript 弹 macOS 原生 UI）----------
# 文案要按 AppleScript 字符串规则转义双引号和反斜杠
as_quote() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
alert()  { osascript -e "display alert \"留声\" message \"$(as_quote "$1")\" as critical" >/dev/null 2>&1 || true; }
dialog() { osascript -e "display dialog \"$(as_quote "$1")\" with title \"留声\" buttons {\"继续\"} default button 1" >/dev/null 2>&1 || true; }
open_browser() { [[ "${LIUSHENG_NO_OPEN:-}" == "1" ]] || open "$URL"; }
port_listening() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

# ---------- 去掉隔离标记 ----------
# 通过浏览器 / AirDrop / 网盘拿到的 .app，里面每个文件都带 com.apple.quarantine。用户在
# 「系统设置」里放行的是 .app 本身，内置的 node / whisper-cli / ffmpeg / mkcert 被 exec 时
# 仍可能被 Gatekeeper 直接 SIGKILL。查一个文件，有标记就整包清掉（用户自己拖进 /Applications
# 的包归用户所有，清得掉；.app 不归当前用户所有时清不掉，要在终端 sudo xattr -cr）
if xattr -p com.apple.quarantine "$BIN/node" >/dev/null 2>&1; then
  log "清除隔离标记"
  xattr -dr com.apple.quarantine "$APP_BUNDLE" 2>/dev/null || true
fi

# ---------- 旧版残局：CA 私钥读不了就作废重建 ----------
# 旧版首次启动以 root 跑 mkcert -install，失败后留下 root 所有、当前用户读不了的 CA 私钥，签发证书必然失败。
# 那个 CA 从没被信任过，作废无损；CAROOT 目录归用户，里面 root 所有的文件也删得掉。
# 删不掉也不在这里退出——下面签发证书会失败并弹提示
if [[ -e "$CAROOT/rootCA-key.pem" && ! -r "$CAROOT/rootCA-key.pem" ]]; then
  log "CA 私钥不可读（旧版以 root 安装失败的残留），重建 CA"
  rm -rf "$CAROOT" "$CA_INSTALLED_MARK" "$CERTS_DIR/cert.pem" "$CERTS_DIR/key.pem" "$SANS_FILE" 2>>"$LOG_FILE" || true
  mkdir -p "$CAROOT"
fi

# ---------- 签发 / 更新 HTTPS 证书（以当前用户身份，不需要密码）----------
# SAN 覆盖 localhost + 本机 .local 名 + 所有局域网 IPv4；和上次不一样（换了 Wi-Fi、IP 变了）就重签。
# CAROOT 里还没有 CA 时 mkcert 会顺带生成（日志里让跑 mkcert -install 的提示不用管，信任在下一段做）
LOCAL_HOST="$(scutil --get LocalHostName 2>/dev/null || true)"
LAN_IPS="$(ifconfig 2>/dev/null | awk '/inet / && $2 != "127.0.0.1" && $2 !~ /^169\.254\./ {print $2}' | sort -u | tr '\n' ' ')"
SANS="localhost 127.0.0.1 ::1 ${LOCAL_HOST:+$LOCAL_HOST.local }$LAN_IPS"
if [[ ! -f "$CERTS_DIR/cert.pem" || ! -f "$CERTS_DIR/key.pem" || "$(cat "$SANS_FILE" 2>/dev/null || true)" != "$SANS" ]]; then
  log "签发证书: $SANS"
  # shellcheck disable=SC2086  # SANS 故意按空格拆成多个参数
  if ! (cd "$CERTS_DIR" && "$BIN/mkcert" -cert-file cert.pem -key-file key.pem $SANS >>"$LOG_FILE" 2>&1); then
    alert "证书生成失败，请查看日志：$LOG_FILE"
    exit 1
  fi
  printf '%s' "$SANS" >"$SANS_FILE"
fi

# ---------- 首次启动：信任本地 CA（macOS 弹一次密码框，只做一次）----------
# 以当前用户身份把 CA 加进登录钥匙串并设为受信任：macOS 自己弹框要本机登录密码，不需要管理员，Safari / Chrome 都认。
# 不能用 osascript 的 with administrator privileges 以 root 跑 mkcert -install：macOS 11 起改证书信任设置
# 必须由系统弹授权框当面确认，那个 root 进程弹不出框，输对密码也会被拒
# （SecTrustSettingsSetTrustSettings: The authorization was denied since no user interaction was possible）
if [[ ! -f "$CA_INSTALLED_MARK" ]]; then
  log "首次启动：信任本地 CA"
  dialog "首次启动需要输入一次本机登录密码，用来信任「留声」的本地 HTTPS 证书。只需一次。"
  if ! security add-trusted-cert -r trustRoot -k "$HOME/Library/Keychains/login.keychain-db" "$CAROOT/rootCA.pem" >>"$LOG_FILE" 2>&1; then
    alert "本地证书安装失败（可能取消了密码框）。请重新打开留声并输入密码。日志：$LOG_FILE"
    exit 1
  fi
  touch "$CA_INSTALLED_MARK"
fi

# ---------- 已在运行：只开浏览器 ----------
# 证书若有变化上面已经重签，正在跑的 server 几秒内会自己热加载（见 server.js「证书热加载」）
if port_listening "$HTTPS_PORT"; then
  log "server 已在 :$HTTPS_PORT 运行，只打开浏览器"
  open_browser
  exit 0
fi

# ---------- 启动 server ----------
# 只出原文 + 本机说话人分离，不调任何云端服务，只听本机
# 说话人分离：模型打在包里；python 运行环境（sherpa-onnx）在 ~/.diar-venv，没有就自动退回纯文字
export LIUSHENG_DIAR_MODELS="$RES/diar-models"
[[ -x "$HOME/.diar-venv/bin/python" ]] && export LIUSHENG_DIAR_PY="$HOME/.diar-venv/bin/python"

# 本机有自编译的 CoreML 版 whisper（Apple 神经引擎，快 ~2.4x）就用它；别的电脑用包内 Metal 版。
# 注意 CoreML 版按模型文件名找编码器（如 ggml-large-v3-turbo-q8_0-encoder.mlmodelc 软链），
# 且拒绝无编码器回退——所以还要求 ~/.whisper-models 里有配套编码器才切换
COREML_CLI="$HOME/.whisper-build/whisper.cpp/build/bin/whisper-cli"
if [[ -x "$COREML_CLI" && -e "$HOME/.whisper-models/ggml-large-v3-turbo-q8_0-encoder.mlmodelc" \
      && -f "$HOME/.whisper-models/ggml-large-v3-turbo-q8_0.bin" ]]; then
  export WHISPER_CLI="$COREML_CLI"
  export WHISPER_MODELS_DIR_OVERRIDE=1
  log "使用本机 CoreML 版 whisper-cli"
fi

# ggml 0.9.x 通过 GGML_BACKEND_PATH 指定 plugin 搜索目录（覆盖编译时硬编码的 brew 路径）
# 不设的话 child 进程拿不到 BLAS/Metal/CPU plugin，会 GGML_ASSERT(device) failed
export GGML_BACKEND_PATH="$BIN"
# server.js 通过环境变量找资源
if [[ "${WHISPER_MODELS_DIR_OVERRIDE:-}" == "1" ]]; then
  export WHISPER_MODELS_DIR="$HOME/.whisper-models"   # CoreML 编码器和模型在这里
else
  export WHISPER_MODELS_DIR="$MODELS"
fi
export CERTS_DIR
export ROOT_CA_PEM="$CAROOT/rootCA.pem"     # 手机装证书时下载的就是这份 CA
export LIUSHENG_DATA_DIR="$DATA_DIR"

log "启动 server（PORT=$PORT HTTPS_PORT=$HTTPS_PORT）"
# server 放后台常驻，启动程序等端口就绪、开完浏览器就退出。不能 exec 成 node 让 .app 进程一直占着：
# macOS 会把 node 登记成「正在运行的留声」，再双击留声 / 桌面快捷方式只会给它发激活事件，node 收不了，
# 报 -1712 超时、浏览器也不开（2026-09-23 放桌面快捷方式时发现）。退出留声 = 在活动监视器里结束 node
cd "$APP_CODE"
nohup "$BIN/node" server.js >>"$LOG_FILE" 2>&1 &
SERVER_PID=$!
disown

# 端口就绪再开浏览器（最多 ~20s）；起不来就弹提示，别让用户对着打不开的页面发呆
for _ in $(seq 1 40); do
  if port_listening "$HTTPS_PORT"; then
    open_browser
    exit 0
  fi
  kill -0 "$SERVER_PID" 2>/dev/null || break   # node 已经退出（端口冲突、缺文件……），不用干等
  sleep 0.5
done
alert "留声启动失败，请查看日志：$LOG_FILE"
exit 1
