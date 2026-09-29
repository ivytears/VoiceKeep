// node tools/corrections.test.js —— 纠错词表的单元测试（秒级跑完）
const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { DEFAULT_TABLE, parseTable, applyCorrections, loadRules } = require('./corrections');

let n = 0;
const test = (name, fn) => { fn(); n += 1; console.log('  ✓', name); };
const rulesOf = table => parseTable(table).rules;
const fix = (text, table = DEFAULT_TABLE) => applyCorrections(text, rulesOf(table));
const tmpDir = () => fs.mkdtempSync(path.join(os.tmpdir(), 'liusheng-corr-'));
// 跑 fn 期间收下 console.warn 的输出（不打到屏幕上）
function captureWarn(fn) {
  const warn = console.warn;
  const out = [];
  console.warn = (...args) => out.push(args.join(' '));
  try { fn(); } finally { console.warn = warn; }
  return out;
}

test('默认表修好实测认错的三个词（2026-09-23 真实录音）', () => {
  assert.strictEqual(fix('大概是用Cloud Code，然后去重建了工作流'), '大概是用Claude Code，然后去重建了工作流');
  assert.strictEqual(fix('海外的GPT和Klod，尤其是美国的GPT和Klod'), '海外的GPT和Claude，尤其是美国的GPT和Claude');
  assert.strictEqual(fix('它肯定是GIMINAN，对吧？Gimilan自己会有'), '它肯定是Gemini，对吧？Gemini自己会有');
});

test('英文不分大小写，词中间的空格可有可无', () => {
  assert.strictEqual(fix('cloud code、CLOUDCODE、Cloud  Code'), 'Claude Code、Claude Code、Claude Code');
  assert.strictEqual(fix('KLOD 和 klod'), 'Claude 和 Claude');
});

test('只换完整的英文词，不动长单词里的片段', () => {
  assert.strictEqual(fix('Klodzko 和 SoundCloud Code'), 'Klodzko 和 SoundCloud Code');
});

test('中文词条照样生效（中文没有词边界）', () => {
  assert.strictEqual(fix('设媒规则', '设媒 => 社媒'), '社媒规则');
});

test('一行多个错写用 | 隔开；注释和空行不生效；也认 → 箭头', () => {
  const rules = rulesOf('# 注释 Klod => 不该生效\n\nfoo | bar => baz\nqux → quux\n');
  assert.strictEqual(rules.length, 2);
  assert.strictEqual(applyCorrections('foo bar qux Klod', rules), 'baz baz quux Klod');
});

test('中文输入法打出的 =》 ＝＞ ｜ 和 -> 也认', () => {
  const rules = rulesOf('设媒 =》 社媒\nKlod ＝＞ Claude\nGIMINAN ｜ Gimilan => Gemini\nfoo -> bar\n');
  assert.strictEqual(rules.length, 4);
  assert.strictEqual(applyCorrections('设媒 Klod GIMINAN Gimilan foo', rules), '社媒 Claude Gemini Gemini bar');
});

test('书名号里的 》 不会被当成箭头', () => {
  assert.strictEqual(fix('他在读《三体》这本书', '《三体》 => 《三体》三部曲'), '他在读《三体》三部曲这本书');
});

test('Windows 换行（CRLF）和文件开头的 BOM 不影响解析', () => {
  const rules = rulesOf('﻿Klod => Claude\r\nfoo => bar\r\n');
  assert.strictEqual(rules.length, 2);
  assert.strictEqual(applyCorrections('Klod foo', rules), 'Claude bar');
});

test('格式不对的行跳过并记下行号，不影响其它行', () => {
  const { rules, skipped } = parseTable('没有箭头的一行\n => 缺错词\n缺正词 =>\nKlod => Claude\n# 注释不算格式错\n');
  assert.strictEqual(rules.length, 1);
  assert.deepStrictEqual(skipped, [1, 2, 3]);
  assert.strictEqual(applyCorrections('Klod', rules), 'Claude');
});

test('错词里的正则特殊字符按字面匹配，正词里的 $ 原样输出', () => {
  assert.strictEqual(fix('A.I. 和 AxIx', 'A.I. => AI'), 'AI 和 AxIx');
  assert.strictEqual(fix('US dollar', 'US dollar => US$'), 'US$');
});

test('重复套用结果不变', () => {
  const once = fix('用Cloud Code和Klod');
  assert.strictEqual(fix(once), once);
});

test('空文本 / 空词表原样返回', () => {
  assert.strictEqual(fix(''), '');
  assert.strictEqual(applyCorrections('Klod', []), 'Klod');
});

test('词表文件不存在：写入默认表，并按默认表纠错', () => {
  const dir = tmpDir();
  const file = path.join(dir, '纠错词表.txt');
  const rules = loadRules(file);
  assert.strictEqual(fs.readFileSync(file, 'utf8'), DEFAULT_TABLE);
  assert.strictEqual(applyCorrections('Klod', rules), 'Claude');
  fs.rmSync(dir, { recursive: true });
});

test('词表文件已存在：完全按文件来（删掉的默认词条不再生效）', () => {
  const dir = tmpDir();
  const file = path.join(dir, '纠错词表.txt');
  fs.writeFileSync(file, 'foo => bar\n');
  assert.strictEqual(applyCorrections('foo Klod', loadRules(file)), 'bar Klod');
  fs.rmSync(dir, { recursive: true });
});

test('读词表时把格式不对的行号写进日志（改了没生效，看日志就知道是哪行）', () => {
  const dir = tmpDir();
  const file = path.join(dir, '纠错词表.txt');
  fs.writeFileSync(file, 'Klod => Claude\n设媒 社媒\n');
  let rules;
  const warns = captureWarn(() => { rules = loadRules(file); });
  assert.strictEqual(applyCorrections('Klod', rules), 'Claude');
  assert.strictEqual(warns.length, 1);
  assert.ok(warns[0].includes('第 2 行'), warns[0]);
  fs.rmSync(dir, { recursive: true });
});

test('词表文件读不了：退回默认表，不抛错', () => {
  const dir = tmpDir();
  let rules;
  const warns = captureWarn(() => { rules = loadRules(dir); });   // 目录当文件读 → EISDIR
  assert.strictEqual(applyCorrections('Klod', rules), 'Claude');
  assert.strictEqual(warns.length, 1);
  fs.rmSync(dir, { recursive: true });
});

console.log(`\n全部 ${n} 项通过 ✓`);
