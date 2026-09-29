#!/usr/bin/env bash
# smoke-test.sh — 在构建机上验证打好的 留声.app 真的自包含、能跑通
#
# 用法: ./packaging/smoke-test.sh [留声.app 路径]      默认 packaging/dist/留声.app
#
# 构建机自己装着 brew，漏打包的依赖在本机根本测不出来。所以所有内置程序都在 sandbox-exec
# 里跑，禁止读 /opt/homebrew 和 /usr/local——目标机没有 brew 时什么样，这里就什么样。
# 素材用系统 TTS 现合成一段中文，不依赖任何外部音频文件。
#
# 覆盖：
#  1) 每个内置二进制能启动（whisper-cli 启动即加载 ggml plugin）；包里没有 .env（AI 网关密钥）
#  2) 内置 ffmpeg 能解前端允许上传的全部格式
#  3) 内置 whisper 能转录中文并走 Metal
#  4) 从 .app 起完整 server（只出原文、只听本机；临时端口 + 临时数据目录），走一遍「上传转录」和
#     「边录边转」两条路，核对转录记录已落盘、不出纪要；只听本机；纠错词表写好了、现改现生效；
#     设置页的 /rootCA.pem、/ca-name 给的是运行时生成的 CA
#  5) 历史记录 / 详情 / 删除，纪要和花名册接口不存在（404），以及路径穿越拦截

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="${1:-$SCRIPT_DIR/dist/留声.app}"
RES="$APP/Contents/Resources"
BIN="$RES/bin"
APP_CODE="$RES/app"
MODELS="$RES/models"
SMOKE_PORT="${SMOKE_PORT:-3100}"
SMOKE_HTTPS_PORT="${SMOKE_HTTPS_PORT:-3543}"
BASE="https://localhost:$SMOKE_HTTPS_PORT"
# 生成测试素材用构建机的 ffmpeg（要 libmp3lame / libopus 编码器，内置版故意不带编码器）
HOST_FFMPEG="${HOST_FFMPEG:-/opt/homebrew/bin/ffmpeg}"

log() { printf "\033[1;36m[smoke]\033[0m %s\n" "$*"; }
ok()  { printf "  \033[1;32m✓\033[0m %s\n" "$*"; }
die() {
  printf "  \033[1;31m✗ %s\033[0m\n" "$*" >&2
  # server 起来之后失败的，把它的日志尾巴带出来，不然临时目录一清什么都看不到了
  if [[ -f "${WORK:-}/server.log" ]]; then
    echo "--- server.log 尾部 ---" >&2
    tail -30 "$WORK/server.log" >&2
  fi
  exit 1
}
# 从 stdin 的 JSON 里取字段：json_get a.b（对象输出 JSON，缺字段输出空串）
json_get() {
  node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let v;try{v=process.argv[1].split(".").reduce((o,k)=>o==null?o:o[k],JSON.parse(s))}catch(e){}console.log(v==null?"":typeof v==="object"?JSON.stringify(v):String(v))})' "$1"
}

[[ -d "$APP" ]] || die "找不到 .app: $APP（先跑 ./packaging/build.sh）"
[[ -x "$HOST_FFMPEG" ]] || die "找不到构建机 ffmpeg: $HOST_FFMPEG（brew install ffmpeg）"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/liusheng-smoke.XXXXXX")"
SERVER_PID=""
cleanup() {
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---------- 沙盒：内置程序看不见 brew ----------
SANDBOX=()
if command -v sandbox-exec >/dev/null; then
  SANDBOX=(sandbox-exec -p '(version 1) (allow default) (deny file-read* (subpath "/opt/homebrew") (subpath "/usr/local"))')
else
  log "警告: 没有 sandbox-exec，无法隔离 brew，测试结果可信度打折"
fi
# bash 3.2 下空数组展开会触发 set -u，用 ${arr[@]+"${arr[@]}"} 写法
run() { ${SANDBOX[@]+"${SANDBOX[@]}"} "$@"; }
# check 描述 命令…：失败就把输出打出来并退出
check() {
  local desc="$1"; shift
  run "$@" >"$WORK/check.out" 2>&1 || { cat "$WORK/check.out" >&2; die "$desc"; }
  ok "$desc"
}

export PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin"
export GGML_BACKEND_PATH="$BIN"

# ---------- 1. 内置程序能启动 ----------
log "1/5 内置程序在沙盒里启动（看不见 /opt/homebrew）"
check "node $(run "$BIN/node" -v 2>/dev/null || echo '(起不来)')"          "$BIN/node" -v
check "mkcert $(run "$BIN/mkcert" -version 2>/dev/null || echo '(起不来)')" "$BIN/mkcert" -version
check "$(run "$BIN/ffmpeg" -version 2>/dev/null | head -1 || echo 'ffmpeg (起不来)')"   "$BIN/ffmpeg" -version
check "$(run "$BIN/ffprobe" -version 2>/dev/null | head -1 || echo 'ffprobe (起不来)')" "$BIN/ffprobe" -version
check "whisper-cli 启动（ggml plugin 加载正常）" "$BIN/whisper-cli" -h
[[ ! -e "$APP_CODE/.env" ]] || die "包里有 .env：留声不调任何云端服务，安装包里不该有密钥"
ok "包里没有 .env（不带 AI 网关密钥）"

# ---------- 2. 合成素材 + ffmpeg 解码全部格式 ----------
log "2/5 内置 ffmpeg 解码前端允许上传的全部格式"
VOICE="$(say -v '?' | awk -F'  +' '/zh_CN/ {print $1; exit}')"
[[ -n "$VOICE" ]] || die "系统没有中文 TTS 语音（系统设置 → 辅助功能 → 朗读内容 → 系统语音 里加一个中文语音）"
TEXT="大家好，今天我们开会讨论三件事。第一，下周的发布计划；第二，客户反馈的问题；第三，团队的排班安排。请大家轮流发言。"
say -v "$VOICE" -o "$WORK/src.aiff" "$TEXT"
SRC_DUR="$(run "$BIN/ffprobe" -v error -show_entries format=duration -of csv=p=0 "$WORK/src.aiff")"
ok "TTS 素材（$VOICE，${SRC_DUR%.*}s）"

mkdir -p "$WORK/in"
# 前端 accept 列表：.m4a,.mp3,.wav,.aac,.ogg,.webm,.caf,.flac
enc() { "$HOST_FFMPEG" -v error -y -i "$WORK/src.aiff" "$@"; }
enc -c:a aac -b:a 64k               "$WORK/in/test.m4a"
enc -c:a libmp3lame -b:a 64k        "$WORK/in/test.mp3"
enc -ar 44100 -ac 2 -c:a pcm_s16le  "$WORK/in/test.wav"
enc -c:a aac -b:a 64k -f adts       "$WORK/in/test.aac"
enc -c:a libopus -b:a 32k -f ogg    "$WORK/in/test.ogg"
enc -c:a libopus -b:a 32k -f webm   "$WORK/in/test.webm"
enc -c:a alac -f caf                "$WORK/in/test.caf"
enc -c:a flac                       "$WORK/in/test.flac"

for f in "$WORK"/in/test.*; do
  out="$WORK/dec_$(basename "$f").wav"
  # 和 server.js transcribeChunk 完全相同的参数
  run "$BIN/ffmpeg" -i "$f" -ar 16000 -ac 1 -c:a pcm_s16le "$out" -y -loglevel warning >"$WORK/dec.log" 2>&1 \
    || { cat "$WORK/dec.log" >&2; die "解码失败: $(basename "$f")"; }
  dur="$(run "$BIN/ffprobe" -i "$out" -show_entries format=duration -v quiet -of csv=p=0)"
  # 解出来的时长和源差 1 秒以上，说明解错了
  awk -v a="$dur" -v b="$SRC_DUR" 'BEGIN { exit (a - b > 1 || b - a > 1) }' \
    || die "$(basename "$f") 解码后时长 ${dur}s ≠ 源 ${SRC_DUR}s"
  ok "$(basename "$f") → 16k 单声道 wav（${dur%.*}s）"
done

# ---------- 3. whisper 转录 ----------
log "3/5 内置 whisper-cli 转录中文（Metal）"
run "$BIN/whisper-cli" -m "$MODELS/ggml-large-v3-turbo-q8_0.bin" -f "$WORK/dec_test.m4a.wav" -l zh -bs 1 \
  --vad --vad-model "$MODELS/ggml-silero-v5.1.2.bin" -otxt -of "$WORK/whisper" >"$WORK/whisper.log" 2>&1 \
  || { tail -20 "$WORK/whisper.log" >&2; die "whisper-cli 运行失败"; }
grep -q "Metal" "$WORK/whisper.log" || die "whisper 日志里没有 Metal，GPU 后端没加载（看 $WORK/whisper.log）"
WHISPER_TEXT="$(tr -d '\n' <"$WORK/whisper.txt")"
[[ -n "$WHISPER_TEXT" ]] || die "whisper 没有输出文本"
echo "$WHISPER_TEXT" | grep -Eq '开会|開會|讨论|討論|客户|客戶|发布|發布|团队|團隊|排班' \
  || die "转录结果对不上素材: $WHISPER_TEXT"
ok "转录: $WHISPER_TEXT"

# ---------- 4. 从 .app 起 server，走两条路 ----------
log "4/5 从 .app 启动 server（:$SMOKE_PORT / :$SMOKE_HTTPS_PORT，临时数据目录）"
mkdir -p "$WORK/certs/CAROOT" "$WORK/data"
(
  cd "$WORK/certs"
  export CAROOT="$WORK/certs/CAROOT"
  run "$BIN/mkcert" -cert-file cert.pem -key-file key.pem localhost 127.0.0.1 ::1
) >"$WORK/mkcert.log" 2>&1 || { cat "$WORK/mkcert.log" >&2; die "mkcert 签发证书失败"; }

(
  cd "$APP_CODE"
  exec env \
    PORT="$SMOKE_PORT" HTTPS_PORT="$SMOKE_HTTPS_PORT" \
    LIUSHENG_DATA_DIR="$WORK/data" CERTS_DIR="$WORK/certs" ROOT_CA_PEM="$WORK/certs/CAROOT/rootCA.pem" \
    WHISPER_MODELS_DIR="$MODELS" \
    ${SANDBOX[@]+"${SANDBOX[@]}"} "$BIN/node" server.js
) >"$WORK/server.log" 2>&1 &
SERVER_PID=$!
disown   # 结束时 kill 它，别让 bash 报一行 "Terminated"

for _ in $(seq 1 40); do
  curl -sk -o /dev/null "$BASE/api/team" 2>/dev/null && break
  sleep 0.5
done
curl -sk -o /dev/null "$BASE/api/team" || die "server 没起来"
ok "server 就绪"

LISTEN="$(lsof -nP -iTCP:"$SMOKE_HTTPS_PORT" -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 {print $9}' | sort -u | tr '\n' ' ')"
[[ "$LISTEN" == *"127.0.0.1:$SMOKE_HTTPS_PORT"* && "$LISTEN" != *"*:"* ]] \
  || die "应只监听 127.0.0.1（接口没有登录，不能对局域网开放），实际: $LISTEN"
ok "只监听本机（$LISTEN）"

grep -q 'Cloud Code => Claude Code' "$WORK/data/纠错词表.txt" 2>/dev/null || die "数据目录里没有写好默认纠错词表"
printf '大家好 => 各位好\n' >>"$WORK/data/纠错词表.txt"   # 现加一条（素材开头就是「大家好」），下面验证不重启就生效
ok "数据目录里写好了默认纠错词表"

curl -s -o "$WORK/dl-ca.pem" "http://localhost:$SMOKE_PORT/rootCA.pem"
cmp -s "$WORK/dl-ca.pem" "$WORK/certs/CAROOT/rootCA.pem" || die "/rootCA.pem 给的不是本次生成的 CA（ROOT_CA_PEM 没生效）"
ok "/rootCA.pem 返回运行时生成的 CA"

EXPECTED_CN="$(openssl x509 -in "$WORK/certs/CAROOT/rootCA.pem" -noout -subject -nameopt multiline | awk -F' = ' '/commonName/ {print $2}')"
CA_NAME="$(curl -s "http://localhost:$SMOKE_PORT/ca-name" | json_get name)"
[[ -n "$CA_NAME" && "$CA_NAME" == "$EXPECTED_CN" ]] || die "/ca-name 返回「$CA_NAME」，证书 CN 是「$EXPECTED_CN」"
ok "/ca-name 返回本次 CA 的名字：$CA_NAME"

# 核对一条 SSE 流的结果 + 落盘记录。$1=SSE 输出文件 $2=描述
check_sse() {
  local sse="$1" desc="$2"
  grep -q '"step":"transcribe_done"' "$sse" || { tail -5 "$sse" >&2; die "$desc：没收到 transcribe_done"; }
  grep -q '"type":"complete"' "$sse" \
    || die "$desc：没有 complete: $(grep '"type":"error"' "$sse" | tail -1)"
  local rec; rec="$(ls -t "$WORK"/data/transcripts/*.json 2>/dev/null | head -1)"
  [[ -n "$rec" ]] || die "$desc：转录记录没落盘"
  local chars; chars="$(json_get transcript <"$rec" | tr -d '\n' | wc -m | tr -d ' ')"
  [[ "$chars" -gt 0 ]] || die "$desc：落盘记录 transcript 为空"
  [[ -z "$(json_get minutes <"$rec")" ]] || die "$desc：不该出纪要"
  ok "$desc：转录已落盘 $(basename "$rec")，不出纪要"
}

# —— 路径 A：整段上传 /api/transcribe ——
curl -sk -N --max-time 900 -F "audio=@$WORK/in/test.m4a" "$BASE/api/transcribe" >"$WORK/sse-upload.txt" || true
check_sse "$WORK/sse-upload.txt" "整段上传"
UP_TX="$(json_get transcript <"$(ls -t "$WORK"/data/transcripts/*.json | head -1)")"
[[ "$UP_TX" == *"各位好"* && "$UP_TX" != *"大家好"* ]] || die "纠错词表没生效（现加的「大家好 => 各位好」）: $UP_TX"
ok "纠错词表生效：现加的「大家好 => 各位好」不重启就用上了"

# —— 路径 B：边录边转 /api/live/{start,chunk,finish}（MediaRecorder 产出 webm/opus，这里也用它）——
"$HOST_FFMPEG" -v error -y -i "$WORK/src.aiff" -t 7    -c:a libopus -b:a 32k -f webm "$WORK/chunk0.webm"
"$HOST_FFMPEG" -v error -y -i "$WORK/src.aiff" -ss 7   -c:a libopus -b:a 32k -f webm "$WORK/chunk1.webm"
SESSION="$(curl -sk -X POST "$BASE/api/live/start" | json_get sessionId)"
[[ -n "$SESSION" ]] || die "live/start 没返回 sessionId"
curl -sk -N --max-time 300 -F "chunk=@$WORK/chunk0.webm" "$BASE/api/live/chunk/$SESSION?index=0" >"$WORK/sse-chunk0.txt" || true
grep -q '"type":"chunk_done"' "$WORK/sse-chunk0.txt" || { cat "$WORK/sse-chunk0.txt" >&2; die "live/chunk 0 没有 chunk_done"; }
ok "边录边转：chunk 0 转录完成"
curl -sk -N --max-time 900 -F "chunk=@$WORK/chunk1.webm" "$BASE/api/live/finish/$SESSION?index=1" >"$WORK/sse-finish.txt" || true
check_sse "$WORK/sse-finish.txt" "边录边转"

# ---------- 5. 历史记录 / 详情 / 编辑 / 重新生成 / 删除 ----------
log "5/5 历史记录与记录管理接口"
IDS="$(ls "$WORK"/data/transcripts/*.json | xargs -n1 basename | sed 's/\.json$//')"
[[ "$(echo "$IDS" | wc -l | tr -d ' ')" -eq 2 ]] || die "应有 2 条落盘记录，实际: $IDS"
HISTORY="$(curl -sk "$BASE/api/history")"
for id in $IDS; do
  [[ "$HISTORY" == *"\"id\":\"$id\""* ]] || die "/api/history 里没有 $id"
done
ok "/api/history 列出 2 条记录"

ID="$(echo "$IDS" | head -1)"
[[ "$(curl -sk "$BASE/api/transcript/$ID" | json_get id)" == "$ID" ]] || die "读不到记录详情 $ID"
[[ -n "$(curl -sk "$BASE/api/transcript/$ID" | json_get transcript)" ]] || die "记录详情里 transcript 为空"
ok "记录详情可读"

for probe in "POST /api/transcript/$ID/regenerate" "PUT /api/transcript/$ID/minutes" "GET /api/team"; do
  code="$(curl -sk -o /dev/null -w '%{http_code}' -X "${probe%% *}" -H 'Content-Type: application/json' -d '{}' "$BASE${probe#* }")"
  [[ "$code" == "404" ]] || die "$probe 应该不存在（没有云端纪要和花名册），实际 HTTP $code"
done
ok "没有任何云端 / 纪要 / 花名册接口（都返回 404）"

CODE="$(curl -sk --path-as-is -o /dev/null -w '%{http_code}' "$BASE/api/transcript/..%2F..%2Fetc%2Fpasswd")"
[[ "$CODE" == "400" ]] || die "路径穿越 ID 没被拦住（HTTP $CODE）"
ok "路径穿越 ID 返回 400"

[[ "$(curl -sk -X DELETE "$BASE/api/transcript/$ID" | json_get ok)" == "true" ]] || die "删除记录失败"
CODE="$(curl -sk -o /dev/null -w '%{http_code}' "$BASE/api/transcript/$ID")"
[[ "$CODE" == "404" ]] || die "删除后仍能读到记录（HTTP $CODE）"
[[ "$(curl -sk "$BASE/api/history")" != *"\"id\":\"$ID\""* ]] || die "删除后 /api/history 仍列出 $ID"
ok "删除记录 → 详情 404、历史里消失"

log "全部通过 ✓"
