// 转录文本清理：幻觉段过滤 + 语气词顺滑
//
// 幻觉：whisper 的训练数据里有海量视频字幕，遇到音乐 / 静音 / 嘈杂段没有真实语音时，
// 会把记忆里的字幕吐出来（「请不吝点赞 订阅 转发 打赏支持明镜与点点栏目」是中文最经典的一句，
// 2026-09-20 在真实会议记录里整段刷屏）。这些句子在正常会议里几乎不可能出现，按黑名单整段删。
// 语气词顺滑：只在「显示说话人」视图里用（纯文字视图保持逐字原文）；规则刻意保守——
// 只删「跟着逗号的口头语气词」和「口头禅连说」，单独成句的「嗯。」「对。」是应答，有语义，不动。

const HALLU_RE = /字幕|点赞|點贊|订阅|訂閱|打赏|打賞|转发|轉發|谢谢观看|謝謝觀看|感谢观看|感謝觀看|下期再见|下期再見|明镜|明鏡|栏目|欄目|独播|獨播|请不吝|請不吝|优优|優優|Amara|amara|MING PAO|Thank you for watching|Subscribe to|ご視聴/;
const TAG_RE = /^\s*[\(（\[【].{0,20}[\)）\]】]\s*$/;          // 「(音乐)」「[掌声]」这类整句标签

// 过滤幻觉段：黑名单整段删；同一句话连续出现 3 次以上，从第 3 次起删（保留 2 次：真人会说「好的。好的。」）
function filterHallucinations(segments) {
  const out = [];
  let dropped = 0;
  let prevText = null;
  let run = 0;
  for (const seg of segments) {
    const t = (seg.text || '').trim();
    if (!t) continue;
    if (HALLU_RE.test(t) || TAG_RE.test(t)) { dropped += 1; continue; }
    run = t === prevText ? run + 1 : 0;
    prevText = t;
    if (run >= 2) { dropped += 1; continue; }
    out.push(seg);
  }
  return { segments: out, dropped };
}

// 语气词顺滑（Typeless 式，保守版）。清完变空说明整段就是语气词，保留原文（多半是应答）
function smoothFillers(text) {
  const out = text
    // 跟着逗号/顿号的口头语气词：「呃,其实」→「其实」；句首句中都清
    .replace(/(^|[,，。？！?!、\s])(呃|嗯|唔|欸|诶|emm|嗯嗯|啊这)[,，、]\s*/g, '$1')
    // 口头禅连说：「就是,就是」「那个那个」→ 一个
    .replace(/(那个|就是|然后|这个)(?:[,，]?\s*\1)+/g, '$1')
    .replace(/\s{2,}/g, ' ')
    .trim();
  return out || text;
}

module.exports = { filterHallucinations, smoothFillers, HALLU_RE };
