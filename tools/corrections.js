// 纠错词表：whisper 怎么调都认不对的专有名词（Claude Code 在 whisper / FireRed / SenseVoice、
// 加不加术语提示词下都被写成 Cloud Code 之类，2026-09-23 实测），转录后按表做确定性替换，只动表里的词。
// 术语提示词两次实测（09-21、09-23）都不稳，还会把别处改错——专有名词只走这张表，别往默认 prompt 里加。
// 词表是数据目录里的「纠错词表.txt」，每次转录现读，改完下一次转录就生效。
const fs = require('fs');

const DEFAULT_TABLE = `# 留声纠错词表：每行「错词 => 正词」，一个正词有几种错写就用 | 隔开
# 英文不分大小写、词中间的空格可有可无，只换完整的词；# 开头的行不生效
# 改完下一次转录就生效，不用重启留声
Cloud Code => Claude Code
Klod => Claude
GIMINAN | Gimilan | Gemina => Gemini
`;

const ALNUM = /[A-Za-z0-9]/;
const escapeRe = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// 英文头尾加边界（前后紧挨着字母数字就不算，免得改到长单词里的片段）；中文没有词边界，照字面匹配
function variantPattern(variant) {
  const body = variant.split(/\s+/).map(escapeRe).join('\\s*');
  const head = ALNUM.test(variant[0]) ? '(?<![A-Za-z0-9])' : '';
  const tail = ALNUM.test(variant[variant.length - 1]) ? '(?![A-Za-z0-9])' : '';
  return head + body + tail;
}

// 箭头认 =>，也认中文输入法下打出来的 =》 ＝＞，以及 -> 和 →（书名号里单独的 》 不算箭头）
const ARROW_LINE = /^(.*?)\s*(?:[=＝][>＞》]|->|→)\s*(.*)$/;
const VARIANT_SEP = /[|｜]/;

// 解析词表文本 → { rules: [{ re, to }], skipped: [格式不对的行号] }
function parseTable(text) {
  const rules = [];
  const skipped = [];
  text.split('\n').forEach((raw, i) => {
    const line = raw.trim();   // 顺带去掉 CRLF 的 \r 和文件开头的 BOM
    if (!line || line.startsWith('#')) return;
    const m = line.match(ARROW_LINE);
    const variants = m ? m[1].split(VARIANT_SEP).map(s => s.trim()).filter(Boolean) : [];
    const to = m ? m[2].trim() : '';
    if (!variants.length || !to) { skipped.push(i + 1); return; }
    rules.push({ re: new RegExp(variants.map(variantPattern).join('|'), 'gi'), to });
  });
  return { rules, skipped };
}

function applyCorrections(text, rules) {
  if (!text) return text;
  return rules.reduce((t, { re, to }) => t.replace(re, () => to), text);
}

// 读词表文件；没有就先写入默认表。读不了不影响转录，退回默认表。
// 每次转录都会读，格式不对的行每次都报行号——「加的词没生效」时看日志就知道是哪行
function loadRules(file) {
  let text;
  try {
    if (!fs.existsSync(file)) fs.writeFileSync(file, DEFAULT_TABLE, 'utf8');
    text = fs.readFileSync(file, 'utf8');
  } catch (err) {
    console.warn(`[纠错] 读不了词表 ${file}，改用默认词表: ${err.message}`);
    return parseTable(DEFAULT_TABLE).rules;
  }
  const { rules, skipped } = parseTable(text);
  if (skipped.length) {
    console.warn(`[纠错] 词表第 ${skipped.join('、')} 行格式不对，没生效（应为「错词 => 正词」）: ${file}`);
  }
  return rules;
}

module.exports = { DEFAULT_TABLE, parseTable, applyCorrections, loadRules };
