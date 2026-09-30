#!/usr/bin/env bash
# server-test.sh — 验证 server.js 的完整流程（不需要模型，约十几秒）
#
# 用法: ./tests/server-test.sh
#
# whisper-cli 和说话人分离都换成桩（记下收到的参数，吐固定文本 / 固定两个人），验证：
# 只监听 127.0.0.1（接口没有登录，不能对局域网开放）；没有任何云端接口（纪要 / 花名册接口都不存在）；
# 上传和边录边转两条路都落盘、过纠错词表（现改词表不用重启）；本机分离标出「说话人一 / 二」且不丢字；
# 整段只有音乐 / 静音（whisper 全吐字幕幻觉）时报「没有识别到说话内容」、不把幻觉存下来。
# 用临时端口 + 临时数据目录，不碰正在跑的留声。

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${SERVER_TEST_PORT:-3300}"
HTTPS_PORT="${SERVER_TEST_HTTPS_PORT:-3743}"
BASE="https://localhost:$HTTPS_PORT"
export PATH="/opt/homebrew/bin:$PATH"   # node / ffmpeg / ffprobe

log() { printf "\033[1;36m[server]\033[0m %s\n" "$*"; }
ok()  { printf "  \033[1;32m✓\033[0m %s\n" "$*"; }
die() {
  printf "  \033[1;31m✗ %s\033[0m\n" "$*" >&2
  if [[ -f "${SERVER_LOG:-}" ]]; then echo "--- server 日志尾部 ---" >&2; tail -15 "$SERVER_LOG" >&2; fi
  exit 1
}
port_listening() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }
# 端口监听在哪个地址上（127.0.0.1:3743 = 只听本机，*:3743 = 所有网卡）
listen_addrs() { lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 {print $9}' | sort -u | tr '\n' ' '; }
# 从 stdin 的 JSON 里取字段：json_get a.b（数组 / 对象输出 JSON，缺字段输出空串）
json_get() {
  node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let v;try{v=process.argv[1].split(".").reduce((o,k)=>o==null?o:o[k],JSON.parse(s))}catch(e){}console.log(v==null?"":typeof v==="object"?JSON.stringify(v):String(v))})' "$1"
}

for p in "$PORT" "$HTTPS_PORT"; do
  ! port_listening "$p" || die "端口 $p 被占用（用 SERVER_TEST_PORT / SERVER_TEST_HTTPS_PORT 换一个）"
done

WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/liusheng-server.XXXXXX")" && pwd)"
SERVER_PID=""
stop_server() {
  [[ -n "$SERVER_PID" ]] || return 0
  kill "$SERVER_PID" 2>/dev/null || true
  for _ in $(seq 1 20); do port_listening "$HTTPS_PORT" || break; sleep 0.5; done
  SERVER_PID=""
}
cleanup() { stop_server; rm -rf "$WORK"; }
trap cleanup EXIT

# ---------- whisper-cli 桩 + 测试音频 ----------
mkdir -p "$WORK/bin"
cat >"$WORK/bin/whisper-cli" <<'EOF'
#!/bin/bash
# 每个参数一行记下来；-of 后面是输出文件前缀，往 <前缀>.txt 写文本、<前缀>.json 写带时间戳的段落
printf '%s\n' "$@" >"$STUB_ARGS_FILE"
prev=""
for a in "$@"; do
  if [[ "$prev" == "-of" ]]; then
    # 文本要超过 100 字：server 有「不足 100 字不做说话人标注」的密度门槛（防空录切出幻觉说话人）
    # 夹着 whisper 实测认错的写法（Cloud Code / Klod / GIMINAN），验证纠错词表
    A="甲方在会议里先用Cloud Code把这个季度的整体情况完整讲了一遍，包括进度、预算和接下来两周要交付的内容，说得比较细。"
    B="乙方听完以后逐条回应了甲方的安排，确认了自己负责的部分和时间点，也提出Klod和GIMINAN两个需要再对齐的问题。"
    # 测试放了 stub-hallu 标记时，模拟整段只有音乐 / 静音：两段全是 whisper 吐的字幕幻觉
    if [[ -f "$(dirname "$STUB_ARGS_FILE")/stub-hallu" ]]; then
      A="请不吝点赞 订阅 转发 打赏支持明镜与点点栏目"; B="$A"
    fi
    printf '%s%s\n' "$A" "$B" >"$a.txt"
    printf '{"transcription":[{"offsets":{"from":0,"to":1000},"text":"%s"},{"offsets":{"from":1000,"to":2000},"text":"%s"}]}' "$A" "$B" >"$a.json"
  fi
  prev="$a"
done
EOF
chmod +x "$WORK/bin/whisper-cli"
# 说话人分离的桩：固定两个人，前一秒甲、后一秒乙（不需要 sherpa-onnx 和模型）
cat >"$WORK/bin/diarize-stub" <<'EOF'
#!/bin/bash
echo '{"speakers":2,"segments":[{"start":0.0,"end":1.0,"speaker":0},{"start":1.0,"end":2.0,"speaker":1}]}'
EOF
chmod +x "$WORK/bin/diarize-stub"
ffmpeg -v error -y -f lavfi -i anullsrc=r=16000:cl=mono -t 2 "$WORK/sample.wav"

SERVER_LOG="$WORK/server.log"
export STUB_ARGS_FILE="$WORK/whisper-args.txt"
DATA="$WORK/data"
mkdir -p "$DATA"
(
  cd "$PROJECT_ROOT"
  exec env PORT="$PORT" HTTPS_PORT="$HTTPS_PORT" LIUSHENG_DATA_DIR="$DATA" WHISPER_CLI="$WORK/bin/whisper-cli" \
    LIUSHENG_DIAR_PY="$WORK/bin/diarize-stub" LIUSHENG_DIAR_SCRIPT="$WORK/bin/diarize-stub" \
    node server.js
) >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
disown   # 结束时 kill 它，别让 bash 报一行 "Terminated"
for _ in $(seq 1 40); do
  curl -sk --noproxy '*' -o /dev/null "$BASE/api/history" 2>/dev/null && break
  sleep 0.5
done
curl -sk --noproxy '*' -o /dev/null "$BASE/api/history" || die "server 没起来"

api() { curl -sk --noproxy '*' "$@"; }
http_code() { api -o /dev/null -w '%{http_code}' "$@"; }
whisper_prompt() { awk 'prev=="--prompt" {print; exit} {prev=$0}' "$STUB_ARGS_FILE"; }
saved_record() { ls -t "$DATA"/transcripts/*.json 2>/dev/null | head -1; }

log "server 流程"

[[ "$(api "$BASE/api/config" | json_get transcriptOnly)" == "true" ]] || die "/api/config 应返回 transcriptOnly: true（前端靠它收起纪要界面）"
ok "/api/config → transcriptOnly: true"

LISTEN="$(listen_addrs "$HTTPS_PORT")$(listen_addrs "$PORT")"
[[ "$LISTEN" == *"127.0.0.1:$HTTPS_PORT"* && "$LISTEN" == *"127.0.0.1:$PORT"* && "$LISTEN" != *"*:"* ]] \
  || die "应只监听 127.0.0.1（接口没有登录，对局域网开放 = 同一 Wi-Fi 的设备能读删记录），实际: $LISTEN"
LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
if [[ -n "$LAN_IP" ]]; then
  ! api --max-time 3 -o /dev/null "https://$LAN_IP:$HTTPS_PORT/api/history" || die "从局域网地址 $LAN_IP 还能访问"
  ok "只监听本机（$LISTEN），从局域网地址 $LAN_IP 连不上"
else
  ok "只监听本机（$LISTEN）；本机没有局域网地址，跳过从局域网连的检查"
fi

CORR="$DATA/纠错词表.txt"
grep -q 'Cloud Code => Claude Code' "$CORR" 2>/dev/null || die "启动时应在数据目录写好默认纠错词表: $CORR"
printf '乙方 => 对方\n' >>"$CORR"   # 不重启，现加一条：下一次转录就该生效
ok "数据目录里有默认纠错词表"

api -N --max-time 120 -F "audio=@$WORK/sample.wav" "$BASE/api/transcribe" >"$WORK/sse-upload.txt" || true
grep -q '"step":"transcribe_done"' "$WORK/sse-upload.txt" || die "没收到 transcribe_done: $(tail -3 "$WORK/sse-upload.txt")"
grep -q '"type":"complete"' "$WORK/sse-upload.txt" || die "转录完应直接 complete: $(tail -3 "$WORK/sse-upload.txt")"
! grep -q '"type":"error"' "$WORK/sse-upload.txt" || die "不该报错: $(grep '"type":"error"' "$WORK/sse-upload.txt")"
REC="$(saved_record)"
[[ -n "$REC" && -n "$(json_get transcript <"$REC")" ]] || die "转录记录没落盘或 transcript 为空"
ok "上传转录：直接 complete，记录已落盘"

TX="$(json_get transcript <"$REC")"
for w in "用Claude Code把" "提出Claude和Gemini两个" "对方听完"; do
  [[ "$TX" == *"$w"* ]] || die "纠错后原文里应有「$w」: $TX"
done
for w in "Cloud Code" Klod GIMINAN 乙方; do
  [[ "$TX" != *"$w"* ]] || die "原文里还有没纠掉的「$w」: $TX"
done
ok "纠错词表生效：Cloud Code→Claude Code、Klod→Claude、GIMINAN→Gemini，现加的「乙方→对方」不重启就生效"

# 词表面板的读写接口：GET 读回文件，PUT 原样保存并报坏行行号（第 6 行故意没有箭头）
[[ "$(api "$BASE/api/corrections" | json_get text)" == *"Cloud Code => Claude Code"* ]] || die "GET /api/corrections 应返回词表内容"
SAVE="$(api -X PUT -H 'Content-Type: application/json' \
  -d '{"text":"Cloud Code => Claude Code\nKlod => Claude\nGIMINAN | Gimilan => Gemini\n乙方 => 对方\n甲方 => 客户\n坏行没有箭头\n"}' \
  "$BASE/api/corrections")"
[[ "$(printf '%s' "$SAVE" | json_get ok)" == "true" ]] || die "PUT /api/corrections 保存失败: $SAVE"
[[ "$(printf '%s' "$SAVE" | json_get rules)" == "5" ]] || die "应报 5 条规则生效: $SAVE"
[[ "$(printf '%s' "$SAVE" | json_get skipped)" == "[6]" ]] || die "应报第 6 行格式不对: $SAVE"
[[ "$(api "$BASE/api/corrections" | json_get text)" == *"甲方 => 客户"* ]] || die "保存后再 GET 应读到新词表"
[[ "$(http_code -X PUT -H 'Content-Type: application/json' -d '{"text":123}' "$BASE/api/corrections")" == "400" ]] || die "text 不是字符串应拒绝"
ok "词表面板接口：GET 读回、PUT 原子保存、坏行报行号、非法请求 400"

ID="$(basename "$REC" .json)"
for probe in "POST /api/transcript/$ID/regenerate" "PUT /api/transcript/$ID/minutes" "GET /api/team"; do
  code="$(http_code -X "${probe%% *}" -H 'Content-Type: application/json' -d '{}' "$BASE${probe#* }")"
  [[ "$code" == "404" ]] || die "$probe 应该不存在（公开版没有云端纪要和花名册），实际 HTTP $code"
done
ok "没有任何云端 / 纪要 / 花名册接口（都返回 404）"

SPK="$(json_get speakerTranscript <"$REC")"
[[ "$SPK" == *"说话人一"* && "$SPK" == *"说话人二"* ]] || die "应标出「说话人一 / 说话人二」，实际: $SPK"
[[ "$SPK" != *"说话人？"* ]] || die "桩的声纹全覆盖，不该出现存疑标记: $SPK"
STRIPPED="$(printf '%s' "$SPK" | sed 's/\[说话人[^]]*\]//g' | tr -d '[:space:]')"
[[ "$STRIPPED" == "$(printf '%s' "$TX" | tr -d '[:space:]')" ]] || die "去掉说话人标签后应和原文逐字相同（不能丢字）: $STRIPPED"
grep -q '"step":"speaker_done"' "$WORK/sse-upload.txt" || die "应发出 speaker_done 事件，前端靠它显示「显示说话人」切换"
ok "本机说话人分离：标出说话人一 / 二，去掉标签后与原文逐字相同"

[[ -n "$(whisper_prompt)" ]] || die "whisper 没收到 --prompt（中文标点靠它带）"
ok "whisper 收到了提示词：$(whisper_prompt)"

SESSION="$(api -X POST "$BASE/api/live/start" | json_get sessionId)"
[[ -n "$SESSION" ]] || die "live/start 没返回 sessionId"
api -N --max-time 120 -F "chunk=@$WORK/sample.wav" "$BASE/api/live/finish/$SESSION?index=0" >"$WORK/sse-live.txt" || true
grep -q '"type":"complete"' "$WORK/sse-live.txt" || die "边录边转没有 complete: $(tail -2 "$WORK/sse-live.txt")"
LIVE_TX="$(json_get transcript <"$(saved_record)")"
[[ "$LIVE_TX" == *"用Claude Code把"* && "$LIVE_TX" != *"Cloud Code"* ]] || die "边录边转的原文没过纠错词表: $LIVE_TX"
ok "边录边转：落盘，原文也过了纠错词表"

touch "$WORK/stub-hallu"
api -N --max-time 120 -F "audio=@$WORK/sample.wav" "$BASE/api/transcribe" >"$WORK/sse-hallu.txt" || true
rm -f "$WORK/stub-hallu"
grep -q '"type":"error"' "$WORK/sse-hallu.txt" || die "整段都是字幕幻觉时应报「没有识别到说话内容」: $(tail -2 "$WORK/sse-hallu.txt")"
! grep -l '明镜' "$DATA"/transcripts/*.json >/dev/null 2>&1 || die "字幕幻觉被存进了转录记录"
ok "整段都是字幕幻觉：报没有识别到说话内容，幻觉没有存下来"

log "全部通过 ✓"
