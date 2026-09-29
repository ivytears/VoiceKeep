#!/usr/bin/env bash
# launcher-test.sh — 验证 .app 启动脚本（Contents/MacOS/留声）的首次启动 / 证书流程
#
# 用法: ./packaging/launcher-test.sh [留声.app 路径]      默认 packaging/dist/留声.app
#
# 信任 CA 那一步由 macOS 弹框要密码，自动化点不了真弹框。这里拼一个假 .app（真 launcher + 真内置程序），
# 把 security / osascript 换成只记参数的桩，验证 launcher 怎么调用它们：
#  1) 全新安装：以当前用户身份（不走 osascript 管理员提权）把签发 server 证书的那个 CA 加进登录钥匙串信任，
#     写标记，server 起得来、证书链对得上；再双击不再要密码，只开浏览器
#  2) 旧版安装失败的残局（CA 私钥当前用户读不了）：自动重建 CA 再信任
#  3) 用户在系统密码框点取消：弹提示、不写标记、不启动 server
# 假 HOME + 临时端口，不碰本机真实的数据目录、日志和钥匙串。
#
# 测不到的：真机上系统授权框能不能弹出来——动了信任方式，要在真机上双击一次确认。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="${1:-$SCRIPT_DIR/dist/留声.app}"
PORT="${LAUNCHER_TEST_PORT:-3200}"
HTTPS_PORT="${LAUNCHER_TEST_HTTPS_PORT:-3643}"

log() { printf "\033[1;36m[launcher]\033[0m %s\n" "$*"; }
ok()  { printf "  \033[1;32m✓\033[0m %s\n" "$*"; }
die() { printf "  \033[1;31m✗ %s\033[0m\n" "$*" >&2; exit 1; }
port_listening() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

[[ -d "$APP" ]] || die "找不到 .app: $APP（先跑 ./packaging/build.sh）"
for p in "$PORT" "$HTTPS_PORT"; do
  ! port_listening "$p" || die "端口 $p 被占用（用 LAUNCHER_TEST_PORT / LAUNCHER_TEST_HTTPS_PORT 换一个）"
done

# cd + pwd 规整掉 TMPDIR 结尾 / 带来的 //，跟 launcher 里算出来的路径逐字对得上
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/liusheng-launcher.XXXXXX")" && pwd)"
STUB_LOG="$WORK/stub.log"
RUN=0

# 成功启动后 node 在后台常驻（启动程序自己已经退出），按端口找到它结束掉
stop_server() {
  local pids
  pids="$(lsof -nP -t -iTCP:"$HTTPS_PORT" -sTCP:LISTEN 2>/dev/null || true)"
  [[ -z "$pids" ]] && return 0
  # shellcheck disable=SC2086  # 可能有多个 pid
  kill $pids 2>/dev/null || true
  for _ in $(seq 1 20); do
    port_listening "$HTTPS_PORT" || return 0
    sleep 0.5
  done
  return 1
}
cleanup() {
  stop_server || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---------- 假 .app：真 launcher + 真内置程序，security / osascript 换成桩 ----------
# launcher 把 Resources/bin 放在 PATH 最前，桩放进去就顶替了系统命令
FAKE="$WORK/留声.app/Contents"
mkdir -p "$FAKE/MacOS" "$FAKE/Resources/bin" "$WORK/tmp"
cp "$APP/Contents/MacOS/留声" "$FAKE/MacOS/留声"
for d in app lib models; do ln -s "$APP/Contents/Resources/$d" "$FAKE/Resources/$d"; done
for f in "$APP/Contents/Resources/bin/"*; do ln -s "$f" "$FAKE/Resources/bin/"; done
# security 桩还记下被调用那一刻证书文件的 sha256：文件那时还不存在（顺序错了）真 security 会失败，桩也失败
cat >"$FAKE/Resources/bin/security" <<'EOF'
#!/bin/bash
printf 'security uid=%s %s\n' "$(id -u)" "$*" >>"$STUB_LOG"
for cert; do :; done
openssl x509 -noout -in "$cert" 2>/dev/null || { echo "证书文件不存在或不是证书: $cert" >&2; exit 1; }
printf 'trusted-ca-sha256 %s\n' "$(shasum -a 256 "$cert" | awk '{print $1}')" >>"$STUB_LOG"
exit "${STUB_SECURITY_EXIT:-0}"
EOF
cat >"$FAKE/Resources/bin/osascript" <<'EOF'
#!/bin/bash
printf 'osascript %s\n' "$*" >>"$STUB_LOG"
EOF
chmod +x "$FAKE/Resources/bin/security" "$FAKE/Resources/bin/osascript"

# 像 Finder 那样用干净环境在后台跑 launcher，退出码写进 $EXIT_FILE（正常启动时开完浏览器就退出，写 0）
# $1=假 HOME，其余是额外环境变量
start_launcher() {
  local home="$1"; shift
  RUN=$((RUN + 1))
  EXIT_FILE="$WORK/exit.$RUN"
  mkdir -p "$home"
  (
    code=0
    env -i HOME="$home" USER="$(id -un)" LOGNAME="$(id -un)" TMPDIR="$WORK/tmp" \
      PATH=/usr/bin:/bin:/usr/sbin:/sbin PORT="$PORT" HTTPS_PORT="$HTTPS_PORT" LIUSHENG_NO_OPEN=1 \
      STUB_LOG="$STUB_LOG" "$@" "$FAKE/MacOS/留声" || code=$?
    echo "$code" >"$EXIT_FILE.tmp" && mv "$EXIT_FILE.tmp" "$EXIT_FILE"
  ) >>"$WORK/launcher.out" 2>&1 &
}
# 等 server 就绪（最多 ~20s）；launcher 先退出了就算失败
wait_server() {
  for _ in $(seq 1 40); do
    port_listening "$HTTPS_PORT" && return 0
    [[ -f "$EXIT_FILE" ]] && return 1
    sleep 0.5
  done
  return 1
}
# 等 launcher 退出（最多 ~20s），输出退出码；到时还在跑输出 timeout
wait_exit_code() {
  for _ in $(seq 1 40); do
    [[ -f "$EXIT_FILE" ]] && { cat "$EXIT_FILE"; return; }
    sleep 0.5
  done
  echo timeout
}
security_calls() { grep -c '^security ' "$STUB_LOG" || true; }
trust_call() { echo "security uid=$(id -u) add-trusted-cert -r trustRoot -k $1/Library/Keychains/login.keychain-db $2"; }
# 被信任的（调用那一刻的）CA 就是现在签发 server 证书的这份 CA。$1=rootCA.pem
trusted_current_ca() { grep -qxF "trusted-ca-sha256 $(shasum -a 256 "$1" | awk '{print $1}')" "$STUB_LOG"; }
# 失败时带上 launcher 输出、server.log 和桩记录。$1=假 HOME
fail() {
  local home="$1"; shift
  {
    echo "--- launcher 输出 ---"; tail -20 "$WORK/launcher.out" 2>/dev/null || true
    echo "--- server.log ---";    tail -30 "$home/Library/Logs/留声/server.log" 2>/dev/null || true
    echo "--- 桩调用 ---";        cat "$STUB_LOG" 2>/dev/null || true
  } >&2
  die "$*"
}

# ---------- 1. 全新安装 ----------
log "1/3 全新安装：首次双击"
H="$WORK/home-fresh"
CERTS="$H/Library/Application Support/留声/certs"
CA="$CERTS/CAROOT/rootCA.pem"
: >"$STUB_LOG"
start_launcher "$H"
wait_server || fail "$H" "server 没起来"
ok "server 就绪"

code="$(wait_exit_code)"
[[ "$code" == "0" ]] || fail "$H" "server 起来后启动程序应开完浏览器就退出（实际: $code）——.app 进程一直占着的话，macOS 把它当成正在运行的留声，再双击只会去激活它（报 -1712），浏览器不开"
port_listening "$HTTPS_PORT" || fail "$H" "启动程序退出后 server 不该跟着退出"
ok "server 起来后启动程序自己退出，server 留在后台（再双击才能真的开浏览器）"

! grep -q 'administrator privileges' "$STUB_LOG" \
  || fail "$H" "还在用 osascript 管理员提权：那个 root 进程弹不出信任授权框，真机上输对密码也会失败"
[[ "$(security_calls)" == "1" ]] || fail "$H" "security 应恰好调用 1 次，实际 $(security_calls) 次"
grep -qxF "$(trust_call "$H" "$CA")" "$STUB_LOG" \
  || fail "$H" "没有以当前用户把 CA 加进登录钥匙串信任，期望调用: $(trust_call "$H" "$CA")"
trusted_current_ca "$CA" || fail "$H" "信任时 CA 文件还没生成，或信任的不是现在这份 CA"
ok "以当前用户身份把 CA 加进登录钥匙串信任（没走管理员提权）"

[[ -f "$CERTS/.ca-installed" ]] || fail "$H" "信任成功后没写 .ca-installed"
[[ -r "$CERTS/CAROOT/rootCA-key.pem" ]] || fail "$H" "CA 私钥当前用户读不了"
openssl verify -CAfile "$CA" "$CERTS/cert.pem" >/dev/null 2>&1 || fail "$H" "cert.pem 不是被信任的那个 CA 签的"
curl -s --noproxy '*' --cacert "$CA" -o /dev/null "https://localhost:$HTTPS_PORT/" \
  || fail "$H" "只信任这个 CA 时 https://localhost:$HTTPS_PORT 证书校验不过"
ok "被信任的 CA 签发了 server 证书，https://localhost 证书链校验通过"

start_launcher "$H"
code="$(wait_exit_code)"
[[ "$code" == "0" ]] || fail "$H" "server 在跑时再次双击应直接退出（退出码 $code）"
[[ "$(security_calls)" == "1" ]] || fail "$H" "再次双击又调了 security：每次打开都会弹密码框"
grep -q '只打开浏览器' "$H/Library/Logs/留声/server.log" || fail "$H" "再次双击没走「已在运行，只打开浏览器」"
ok "再次双击：不再要密码，只开浏览器"
stop_server || fail "$H" "server 结束不掉"

# ---------- 2. 旧版安装失败的残局 ----------
log "2/3 旧版安装失败的残局：CA 私钥当前用户读不了"
H="$WORK/home-broken"
CERTS="$H/Library/Application Support/留声/certs"
CA="$CERTS/CAROOT/rootCA.pem"
mkdir -p "$CERTS/CAROOT"
# 造一个旧 CA，把私钥设成读不了（真机上是 root 所有的 0400，对当前用户效果一样）
CAROOT="$CERTS/CAROOT" "$APP/Contents/Resources/bin/mkcert" -cert-file "$WORK/old.pem" -key-file "$WORK/old-key.pem" localhost \
  >/dev/null 2>&1 || die "造旧 CA 失败"
chmod 000 "$CERTS/CAROOT/rootCA-key.pem"
OLD_CA_SUM="$(shasum -a 256 "$CA" | awk '{print $1}')"
: >"$STUB_LOG"
start_launcher "$H"
wait_server || fail "$H" "残局下 server 没起来（没有自动重建 CA？）"
[[ "$(shasum -a 256 "$CA" | awk '{print $1}')" != "$OLD_CA_SUM" ]] || fail "$H" "CA 没有重建"
[[ -r "$CERTS/CAROOT/rootCA-key.pem" ]] || fail "$H" "重建后 CA 私钥仍然读不了"
grep -qxF "$(trust_call "$H" "$CA")" "$STUB_LOG" && trusted_current_ca "$CA" || fail "$H" "重建 CA 后没有信任新 CA"
[[ -f "$CERTS/.ca-installed" ]] || fail "$H" "重建并信任后没写 .ca-installed"
openssl verify -CAfile "$CA" "$CERTS/cert.pem" >/dev/null 2>&1 || fail "$H" "cert.pem 不是新 CA 签的"
ok "自动重建 CA → 重新信任 → server 正常起来"
stop_server || fail "$H" "server 结束不掉"

# ---------- 3. 用户取消系统密码框 ----------
log "3/3 用户在系统密码框点了取消"
H="$WORK/home-cancel"
CERTS="$H/Library/Application Support/留声/certs"
: >"$STUB_LOG"
start_launcher "$H" STUB_SECURITY_EXIT=1
code="$(wait_exit_code)"
[[ "$code" != "timeout" ]] || fail "$H" "取消后 launcher 没退出（把 server 起来了？）"
[[ "$code" != "0" ]] || fail "$H" "取消后 launcher 应该失败退出"
[[ "$(security_calls)" == "1" ]] || fail "$H" "security 应调用 1 次，实际 $(security_calls) 次"
[[ ! -f "$CERTS/.ca-installed" ]] || fail "$H" "取消了还写 .ca-installed：以后再也不会要求信任"
grep -q '本地证书安装失败' "$STUB_LOG" || fail "$H" "取消后没有弹失败提示"
! port_listening "$HTTPS_PORT" || fail "$H" "取消后不该启动 server"
ok "取消密码框：弹提示、不写标记、不启动 server（下次双击重新要密码）"

log "全部通过 ✓"
