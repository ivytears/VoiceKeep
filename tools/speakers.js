// 把本机说话人分离的区间和 whisper 的段落合并成「[说话人一] 文本」
//
// 单独成文件是为了能脱离 server 直接测（node tools/speakers.test.js）。
// 设计依据（2026-09-20 实测 + 评审复核，都在真实录音上验证过）：
//   - 分离区间**会互相重叠**（24 个区间里 10 对重叠），必须按「重叠时长累加投票」，中点归属会错
//   - 分离结果有空洞，whisper 在空洞里照样出字 → 字绝不能丢；但空洞里的归属是猜的：
//       前后都是同一个人且缺口都 ≤5 秒 → 静默继承（正常的换气停顿）
//       其它情况（前后不是同一个人 / 缺口太深 / 附和词）→ 照样给字，但整轮标「说话人？」
//     评审实锤：旧版一律静默继承，远场录音 19%~45% 的字是零证据标签，换人边界必然张冠李戴
//   - 空洞里 ≤6 个字的附和词（对/嗯/是的/OK…）经常是对方说的，并进独白就是安错人 → 一律存疑
//   - VAD 偶尔把 ≥15 秒的对话吐成一个大段，段内两个人抢票 → 胜者票不过 60% 就存疑
//   - 英文相邻段 join('') 会把单词粘连（段首空格被 trim 掉了）→ ASCII 边界补空格

const CN_NUM = '一二三四五六七八九十';
const INHERIT_MAX_GAP_S = 5;      // 静默继承允许的最大缺口（秒）
const MEGA_SEG_MS = 15000;        // 「大段」门槛：超过它且两人抢票就要看胜者份额
const MEGA_MIN_SHARE = 0.6;       // 大段里胜者票占比低于它 → 存疑
const BACKCHANNEL = /^[\s，。、！？!?～~…\-]*([对嗯是好哦噢喔呃啊行]{1,3}|是的|对的|对对对|好的|明白|OK|ok|Okay|okay|Yeah|yeah)[\s，。、！？!?～~…\-]*$/;

function speakerName(index) {
  return index < CN_NUM.length ? `说话人${CN_NUM[index]}` : `说话人${index + 1}`;
}

// 给每个 whisper 段落配说话人。segments: [{t0,t1,text}]（毫秒）；diar: [{start,end,speaker}]（秒）
// 返回 [{...seg, speaker, uncertain, confidence}]；字数永远守恒，不确定的只是标记，不丢内容
function assignSpeakers(segments, diar) {
  let last = null;
  return segments.map((seg) => {
    const s = seg.t0 / 1000;
    const e = seg.t1 / 1000;
    const votes = new Map();
    for (const d of diar) {
      const ov = Math.min(e, d.end) - Math.max(s, d.start);
      if (ov > 0) votes.set(d.speaker, (votes.get(d.speaker) || 0) + ov);
    }
    if (votes.size > 0) {
      let best = null;
      let bestOv = -1;
      let total = 0;
      for (const [spk, ov] of votes) {
        total += ov;
        if (ov > bestOv) { bestOv = ov; best = spk; }
      }
      const share = total > 0 ? bestOv / total : 0;
      // 大段 + 两人抢票 + 胜者份额低 → 段内多半混着两个人的话，别装作很确定
      const uncertain = (seg.t1 - seg.t0) >= MEGA_SEG_MS && votes.size >= 2 && share < MEGA_MIN_SHARE;
      last = best;
      return { ...seg, speaker: best, uncertain, confidence: share };
    }
    // ---- 声纹空洞：没有任何票 ----
    let prev = null;   // 空洞前最近的分离区间
    let next = null;   // 空洞后最近的分离区间
    for (const d of diar) {
      if (d.end <= s && (!prev || d.end > prev.end)) prev = d;
      if (d.start >= e && (!next || d.start < next.start)) next = d;
    }
    const gapPrev = prev ? s - prev.end : Infinity;
    const gapNext = next ? next.start - e : Infinity;
    const isBackchannel = BACKCHANNEL.test(seg.text);
    const sameBothSides = prev && next && prev.speaker === next.speaker
      && gapPrev <= INHERIT_MAX_GAP_S && gapNext <= INHERIT_MAX_GAP_S;
    // 猜一个最近的说话人当标签底色（uncertain 时轮次标「说话人？」，这个值只影响相邻轮合并）
    const guess = gapPrev <= gapNext ? (prev ? prev.speaker : (next ? next.speaker : (last ?? 0)))
      : (next ? next.speaker : (prev ? prev.speaker : (last ?? 0)));
    if (sameBothSides && !isBackchannel) {
      last = prev.speaker;
      return { ...seg, speaker: prev.speaker, uncertain: false, confidence: 0 };
    }
    return { ...seg, speaker: guess, uncertain: true, confidence: 0 };
  });
}

// ASCII 相邻时补空格（中文直接相连；英文 trim 掉段首空格后不补会粘词）
function joinTexts(texts) {
  let out = '';
  for (const t of texts) {
    if (out && /[\x21-\x7E]$/.test(out) && /^[A-Za-z0-9([`'"]/.test(t)) out += ' ';
    out += t;
  }
  return out;
}

// 合并成带说话人的文本：同说话人、同确定性的连续段并成一轮；存疑轮标「说话人？」
function formatSpeakerTranscript(assigned) {
  const turns = [];
  for (const seg of assigned) {
    const prev = turns[turns.length - 1];
    if (prev && prev.speaker === seg.speaker && prev.uncertain === seg.uncertain) prev.texts.push(seg.text);
    else turns.push({ speaker: seg.speaker, uncertain: seg.uncertain, texts: [seg.text] });
  }
  return turns.map((t) => `[${t.uncertain ? '说话人？' : speakerName(t.speaker)}] ${joinTexts(t.texts)}`).join('\n');
}

// 入口：whisper 段落 + 分离结果 → { text, speakers, turns, uncertainChars, totalChars }
// 给不出结果就返回 null（调用方回退纯文字）
function buildSpeakerTranscript(segments, diarization) {
  if (!segments || !segments.length) return null;
  const diar = (diarization && diarization.segments) || [];
  if (!diar.length) return null;
  const speakers = new Set(diar.map((d) => d.speaker)).size;
  if (speakers < 2) return null;              // 只有一个人，标了也没意义
  const assigned = assignSpeakers(segments, diar);
  const text = formatSpeakerTranscript(assigned);
  const totalChars = assigned.reduce((a, x) => a + x.text.length, 0);
  const uncertainChars = assigned.reduce((a, x) => a + (x.uncertain ? x.text.length : 0), 0);
  return { text, speakers, turns: text.split('\n').length, uncertainChars, totalChars };
}

module.exports = { speakerName, assignSpeakers, joinTexts, formatSpeakerTranscript, buildSpeakerTranscript };
