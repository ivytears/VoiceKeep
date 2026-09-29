// node tools/speakers.test.js —— 合并逻辑的单元测试（不需要模型，秒级跑完）
const assert = require('assert');
const { assignSpeakers, formatSpeakerTranscript, buildSpeakerTranscript, speakerName, joinTexts } = require('./speakers');

const seg = (t0, t1, text) => ({ t0, t1, text });
let n = 0;
const test = (name, fn) => { fn(); n += 1; console.log('  ✓', name); };

test('说话人序号用中文，超过十个回落成数字', () => {
  assert.strictEqual(speakerName(0), '说话人一');
  assert.strictEqual(speakerName(9), '说话人十');
  assert.strictEqual(speakerName(10), '说话人11');
});

test('按重叠时长投票，不是按中点', () => {
  const out = assignSpeakers([seg(0, 10000, '喂')], [
    { start: 0, end: 6, speaker: 0 },
    { start: 3, end: 10, speaker: 1 },
  ]);
  assert.strictEqual(out[0].speaker, 1);
  assert.strictEqual(out[0].uncertain, false);   // 10 秒段不到大段门槛，正常投票
  assert.ok(out[0].confidence > 0.5);
});

test('区间重叠时两边都计票', () => {
  const out = assignSpeakers([seg(0, 4000, 'a'), seg(4000, 8000, 'b')], [
    { start: 0, end: 5, speaker: 0 },
    { start: 3, end: 8, speaker: 1 },
  ]);
  assert.deepStrictEqual(out.map((s) => s.speaker), [0, 1]);
});

test('浅空洞、前后同一个人：静默继承，不丢字', () => {
  const out = assignSpeakers([seg(0, 2000, '一'), seg(5000, 7000, '继续说'), seg(10000, 12000, '三')], [
    { start: 0, end: 2, speaker: 0 },
    { start: 10, end: 12, speaker: 0 },
  ]);
  assert.deepStrictEqual(out.map((s) => [s.speaker, s.uncertain]), [[0, false], [0, false], [0, false]]);
  assert.strictEqual(out.map((s) => s.text).join(''), '一继续说三');
});

test('空洞卡在换人边界（前后不同人）：不硬继承，标存疑', () => {
  const out = assignSpeakers([seg(5000, 7000, '这句在洞里')], [
    { start: 0, end: 4, speaker: 0 },
    { start: 10, end: 12, speaker: 1 },
  ]);
  assert.strictEqual(out[0].uncertain, true);
  assert.strictEqual(out[0].text, '这句在洞里');
});

test('深空洞（缺口 >5 秒）即使前后同人也标存疑', () => {
  const out = assignSpeakers([seg(20000, 22000, '隔了很久的话')], [
    { start: 0, end: 2, speaker: 0 },
    { start: 60, end: 62, speaker: 0 },
  ]);
  assert.strictEqual(out[0].uncertain, true);
});

test('空洞里的附和词（对/嗯/好的）一律存疑——经常是对方说的', () => {
  const out = assignSpeakers([seg(5000, 5600, '嗯。'), seg(6000, 6500, '对对对')], [
    { start: 0, end: 4.8, speaker: 0 },
    { start: 6.8, end: 12, speaker: 0 },
  ]);
  assert.deepStrictEqual(out.map((s) => s.uncertain), [true, true]);
});

test('开头就落在空洞里：跟最近的区间猜，标存疑，不炸', () => {
  const out = assignSpeakers([seg(0, 1000, '喂')], [{ start: 50, end: 60, speaker: 1 }]);
  assert.strictEqual(out[0].speaker, 1);
  assert.strictEqual(out[0].uncertain, true);
});

test('大段（≥15 秒）两人抢票且胜者不过 60%：存疑', () => {
  const out = assignSpeakers([seg(0, 20000, '两个人的话混在一段里')], [
    { start: 0, end: 11, speaker: 0 },
    { start: 11, end: 20, speaker: 1 },
  ]);
  assert.strictEqual(out[0].speaker, 0);
  assert.strictEqual(out[0].uncertain, true);
});

test('大段但一边压倒性（>60%）：正常归属', () => {
  const out = assignSpeakers([seg(0, 20000, '基本是一个人在讲')], [
    { start: 0, end: 16, speaker: 0 },
    { start: 16, end: 20, speaker: 1 },
  ]);
  assert.strictEqual(out[0].uncertain, false);
});

test('平票时取先出现的说话人，结果稳定', () => {
  const out = assignSpeakers([seg(0, 8000, 'x')], [
    { start: 0, end: 4, speaker: 0 },
    { start: 4, end: 8, speaker: 1 },
  ]);
  assert.strictEqual(out[0].speaker, 0);
});

test('零长段不炸、按空洞逻辑处理', () => {
  const out = assignSpeakers([seg(3000, 3000, '')], [{ start: 0, end: 2, speaker: 0 }, { start: 4, end: 6, speaker: 0 }]);
  assert.strictEqual(out.length, 1);
});

test('英文相邻段拼接补空格，中文不补', () => {
  assert.strictEqual(joinTexts(['news release', 'press kit']), 'news release press kit');
  assert.strictEqual(joinTexts(['你好。', '再见。']), '你好。再见。');
  assert.strictEqual(joinTexts(['说的是 GTM.', 'And then?']), '说的是 GTM. And then?');
});

test('连续同一个人合并成一段；存疑轮单独成轮、标「说话人？」', () => {
  const text = formatSpeakerTranscript([
    { text: '你好', speaker: 0, uncertain: false }, { text: '在吗', speaker: 0, uncertain: false },
    { text: '嗯。', speaker: 0, uncertain: true }, { text: '在的', speaker: 1, uncertain: false },
  ]);
  assert.strictEqual(text, '[说话人一] 你好在吗\n[说话人？] 嗯。\n[说话人二] 在的');
});

test('只有一个说话人时返回 null（回退纯文字）', () => {
  assert.strictEqual(buildSpeakerTranscript([seg(0, 1000, 'x')], { speakers: 1, segments: [{ start: 0, end: 1, speaker: 0 }] }), null);
});

test('分离失败 / 空结果 / 没有段落时返回 null', () => {
  assert.strictEqual(buildSpeakerTranscript([seg(0, 1000, 'x')], null), null);
  assert.strictEqual(buildSpeakerTranscript([seg(0, 1000, 'x')], { speakers: 0, segments: [] }), null);
  assert.strictEqual(buildSpeakerTranscript([], { speakers: 2, segments: [{ start: 0, end: 1, speaker: 0 }, { start: 1, end: 2, speaker: 1 }] }), null);
});

test('正常两人对话：字数守恒 + 存疑统计', () => {
  const segments = [seg(0, 3000, '你好我是面试官'), seg(3500, 4000, '嗯。'), seg(6000, 9000, '先自我介绍一下')];
  const r = buildSpeakerTranscript(segments, { speakers: 2, segments: [
    { start: 0, end: 3, speaker: 0 }, { start: 6, end: 9, speaker: 0 },
  ].concat([{ start: 20, end: 30, speaker: 1 }]) });
  assert.strictEqual(r.speakers, 2);
  const plain = r.text.replace(/\[说话人[^\]]*\]\s?/g, '').replace(/\n/g, '');
  assert.strictEqual(plain, segments.map((s) => s.text).join(''));
  assert.strictEqual(r.totalChars, segments.reduce((a, s) => a + s.text.length, 0));
  assert.strictEqual(r.uncertainChars, 2);      // 「嗯。」是空洞附和词
});

console.log(`\n全部 ${n} 项通过 ✓`);
