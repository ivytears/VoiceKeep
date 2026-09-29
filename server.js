const express = require('express');
const multer = require('multer');
const { execFile } = require('child_process');
const crypto = require('crypto');
const path = require('path');
const fs = require('fs');
const os = require('os');
const OpenCC = require('opencc-js');

// 确保 Homebrew 工具（ffmpeg, whisper-cli 等）在 PATH 中。追加到末尾而不是插到开头：
// .app 启动时 PATH 最前面是内置的 bin/，插到开头会让装了 brew 的机器绕过内置版本
if (!process.env.PATH?.includes('/opt/homebrew/bin')) {
  process.env.PATH = `${process.env.PATH}:/opt/homebrew/bin`;
}

// ────── 工具函数 ──────

// execFile 的 Promise 包装（不阻塞事件循环）
function execFileAsync(cmd, args, opts = {}) {
  return new Promise((resolve, reject) => {
    execFile(cmd, args, opts, (err, stdout, stderr) => {
      if (err) { err.stderr = stderr; reject(err); }
      else resolve({ stdout, stderr });
    });
  });
}

// 简单信号量：限制 whisper 并发数为 1，避免 CPU 争抢
class Semaphore {
  constructor(max) { this.max = max; this.current = 0; this.queue = []; }
  async acquire() {
    if (this.current < this.max) { this.current++; return; }
    await new Promise(resolve => this.queue.push(resolve));
  }
  release() {
    this.current--;
    if (this.queue.length > 0) { this.current++; this.queue.shift()(); }
  }
}
const whisperSemaphore = new Semaphore(1);

const app = express();
const PORT = process.env.PORT || 3000;

// Paths
// 数据目录支持通过环境变量覆盖（.app 打包时把可写数据放到 ~/Library/Application Support/）
const DATA_DIR = process.env.LIUSHENG_DATA_DIR || __dirname;
const UPLOAD_DIR = path.join(DATA_DIR, 'uploads');
const TRANSCRIPT_DIR = path.join(DATA_DIR, 'transcripts');
// 模型目录支持环境变量覆盖；默认走 ~/.whisper-models（本地开发兼容）
const MODELS_DIR = process.env.WHISPER_MODELS_DIR || path.join(os.homedir(), '.whisper-models');
// large-v3-turbo: 比 large-v3 快 5-7x。优先 q8_0（2026-09-20 实测：修复 Air Native→AI native、
// Teen→Team、重购→重构，远场多转出 30% 内容），没有再退回 q5_0
const MODEL_PATH = ['ggml-large-v3-turbo-q8_0.bin', 'ggml-large-v3-turbo-q5_0.bin']
  .map(f => path.join(MODELS_DIR, f)).find(f => fs.existsSync(f)) || path.join(MODELS_DIR, 'ggml-large-v3-turbo-q5_0.bin');
// Silero VAD: 静音段直接跳过，并在静音处切句而不是硬切，减少幻觉与漏字
const VAD_MODEL_PATH = path.join(MODELS_DIR, 'ggml-silero-v5.1.2.bin');
// whisper-cli 二进制：默认用 PATH 上的 brew 版；设环境变量 WHISPER_CLI 可指向自编译的
// CoreML 版（神经引擎加速，实测整体快 ~2.4x）。模型目录放好 *-encoder.mlmodelc 即自动启用
const WHISPER_BIN = process.env.WHISPER_CLI || 'whisper-cli';
// 本机说话人分离（sherpa-onnx，离线）：装了 ~/.diar-venv 就自动启用，没有就只出纯文字
const DIAR_PY = process.env.LIUSHENG_DIAR_PY || path.join(os.homedir(), '.diar-venv/bin/python');
const DIAR_SCRIPT = process.env.LIUSHENG_DIAR_SCRIPT || path.join(__dirname, 'tools', 'diarize.py');
const DIAR_ENABLED = fs.existsSync(DIAR_PY) && fs.existsSync(DIAR_SCRIPT);
const { buildSpeakerTranscript } = require('./tools/speakers');
const { filterHallucinations, smoothFillers } = require('./tools/textclean');
const { loadRules: loadCorrections, applyCorrections } = require('./tools/corrections');
console.log(DIAR_ENABLED ? '[diar] 说话人分离已启用' : `[diar] 说话人分离未启用（缺 ${fs.existsSync(DIAR_PY) ? DIAR_SCRIPT : DIAR_PY}）`);
const diarSemaphore = new Semaphore(1);   // 2 小时录音峰值内存约 2.7GB，不并发
// 转录密度门槛：每「语音分钟」不到这么多字就不标说话人（空录、环境噪声上做分离只会切出幻觉说话人，
// 实测一段 240 秒、69 字的极弱录音被切成 4 个人）。分母是 whisper 段落的语音时长而不是全片时长——
// 大半静音、中间有真实对话的长录音不能被误挡（评审抓出来的）；另有 100 字的绝对下限
const DIAR_MIN_CHARS_PER_MIN = 40;

[UPLOAD_DIR, TRANSCRIPT_DIR].forEach(dir => {
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
});

// 纠错词表在数据目录里，要加词改这个文件就行（没有就写入默认表，见 tools/corrections.js）
const CORRECTIONS_FILE = path.join(DATA_DIR, '纠错词表.txt');
console.log(`[纠错] 词表 ${CORRECTIONS_FILE}（${loadCorrections(CORRECTIONS_FILE).length} 条）`);

// P0 fix: validate transcript ID to prevent path traversal
function safeTranscriptPath(id) {
  if (!id || /[\/\\]|\.\./.test(id)) return null;
  const resolved = path.resolve(TRANSCRIPT_DIR, `${id}.json`);
  if (!resolved.startsWith(path.resolve(TRANSCRIPT_DIR) + path.sep)) return null;
  return resolved;
}

// Traditional → Simplified Chinese conversion (纯 JS，不再 spawn 进程)
const t2sConverter = OpenCC.Converter({ from: 'tw', to: 'cn' });
function toSimplified(text) {
  try { return t2sConverter(text); }
  catch (e) { return text; }
}

// P1 fix: cleanup expired files on startup and every hour
function cleanupExpiredFiles() {
  const now = Date.now();
  const EXPIRY_MS = 24 * 60 * 60 * 1000;
  // 清理过期的 transcripts（结果 JSON）
  try {
    for (const f of fs.readdirSync(TRANSCRIPT_DIR).filter(f => f.endsWith('.json'))) {
      const fp = path.join(TRANSCRIPT_DIR, f);
      if (now - fs.statSync(fp).mtimeMs > EXPIRY_MS) {
        fs.unlinkSync(fp);
        console.log(`[cleanup] Deleted expired transcript: ${f}`);
      }
    }
  } catch (e) {}
  // 清理过期的上传临时文件（multer 处理完通常会自删，此处兜底防泄漏）
  try {
    for (const f of fs.readdirSync(UPLOAD_DIR)) {
      const fp = path.join(UPLOAD_DIR, f);
      if (now - fs.statSync(fp).mtimeMs > EXPIRY_MS) {
        fs.unlinkSync(fp);
        console.log(`[cleanup] Deleted expired upload: ${f}`);
      }
    }
  } catch (e) {}
}
cleanupExpiredFiles();
setInterval(cleanupExpiredFiles, 60 * 60 * 1000);

// Multer config
const upload = multer({
  dest: UPLOAD_DIR,
  limits: { fileSize: 500 * 1024 * 1024 },
  fileFilter: (req, file, cb) => {
    const allowed = ['.m4a', '.mp3', '.mp4', '.wav', '.aac', '.ogg', '.webm', '.caf', '.flac'];
    const ext = path.extname(file.originalname).toLowerCase();
    cb(null, allowed.includes(ext));
  }
});

app.use(express.static('public'));
app.use(express.json({ limit: '500kb' }));

// whisper 的 initial prompt：一句中性的开场白，让输出带上中文标点
const WHISPER_PROMPT = '以下是普通话的对话录音，请看文字记录。';

// ────── 共享函数 ──────

// SSE 心跳间隔：标注/纪要阶段等 LLM 首字或重试退避时 SSE 会静默几十秒，长连接一静默
// 就易被 iOS 后台休眠 / 代理 idle 超时切断。每 15s 发一个注释行（冒号开头，前端只解析
// data: 行会自动忽略）保活。
const SSE_HEARTBEAT_MS = 15000;

// 打开一条 SSE 响应，四个流式端点共用，保证"三件套"不漂移：
// ① 心跳保活（客户端真断了再清掉，避免空转写死 socket）；
// ② sendEvent 包 try/catch——客户端断线后服务端要继续在后台跑完并落盘，写已关闭的
//    socket 不能抛错中断流程；
// ③ 长音频转录可能超过 2 小时，显式禁用 socket 超时。
function openSSE(req, res) {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    'Connection': 'keep-alive',
  });
  res.socket && res.socket.setTimeout(0);

  const heartbeat = setInterval(() => {
    try { res.write(`: hb ${Date.now()}\n\n`); } catch (e) {}
  }, SSE_HEARTBEAT_MS);
  req.on('close', () => clearInterval(heartbeat));

  return {
    sendEvent: (type, data) => {
      try { res.write(`data: ${JSON.stringify({ type, ...data })}\n\n`); } catch (e) {}
    },
    end: () => {
      clearInterval(heartbeat);
      res.end();
    },
  };
}

// 记录 ID：时间戳 + 随机后缀（也是落盘文件名）
function newRecordId(prefix = '') {
  const timestamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
  return `${prefix}${timestamp}_${crypto.randomBytes(6).toString('hex')}`;
}

// 落盘一条转录记录。转录是最贵且不可重来的产物——一完成就先存，之后标注/纪要每阶段
// 完成再 immutable 更新同一条记录重存；任何后续失败或客户端断线都不丢转录。
function saveTranscriptRecord(record) {
  try {
    fs.writeFileSync(path.join(TRANSCRIPT_DIR, `${record.id}.json`), JSON.stringify(record, null, 2), 'utf8');
  } catch (e) {
    console.error('[save] 记录写入失败:', e.message);
  }
}

// 本机说话人分离：spawn ~/.diar-venv 里的 python 跑 tools/diarize.py，拿 {speakers, segments:[{start,end,speaker}]}
// 失败一律返回 null —— 说话人标注是附加产物，绝不能影响转录（项目铁律）
async function diarizeAudio(wavPath) {
  if (!DIAR_ENABLED) return null;
  await diarSemaphore.acquire();
  const t0 = Date.now();
  try {
    // 注意：静音时 sherpa-onnx 会往 stderr 打 "No speakers found"，stderr 非空不代表失败，只看退出码
    const { stdout } = await execFileAsync(DIAR_PY, [DIAR_SCRIPT, wavPath], { timeout: 1800000, maxBuffer: 32 * 1024 * 1024 });
    const r = JSON.parse(stdout);
    console.log(`[diar] ${r.skipped ? '跳过(' + r.skipped + ')' : r.speakers + ' 人'}，用时 ${Math.round((Date.now() - t0) / 1000)}s`);
    return r;
  } catch (e) {
    console.error('[diar] 分离失败，回退纯文字:', e.message);
    return null;
  } finally {
    diarSemaphore.release();
  }
}

// 读 whisper -oj 输出的段落，转成 [{t0,t1,text}]（毫秒）；offsetMs 用于长音频分段时补回绝对时间
function readWhisperSegments(jsonPath, offsetMs = 0) {
  try {
    const data = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
    return (data.transcription || []).map(seg => ({
      t0: (seg.offsets ? seg.offsets.from : 0) + offsetMs,
      t1: (seg.offsets ? seg.offsets.to : 0) + offsetMs,
      text: collapseRepeats(toSimplified((seg.text || '').trim())),
    })).filter(s => s.text);
  } catch (e) {
    return [];
  }
}

// 构建 whisper-cli 参数（分段/整段两处调用共用，保证一致，避免参数漂移）
function buildWhisperArgs(wavFile, outBase, threads) {
  return [
    '-m', MODEL_PATH, '-f', wavFile, '-l', 'zh',
    '-t', String(threads),
    '-bs', '5',   // 束搜索（2026-09-20 实测：AI native 识出率 1/2→2/2，代价约 1.6x 解码时间，仍 >10x 实时）
    '--vad', '--vad-model', VAD_MODEL_PATH,
    '--vad-min-silence-duration-ms', '500',
    '--suppress-nst',           // 抑制非语音 token（静音/音乐处的幻觉来源）
    '--entropy-thold', '2.8',   // 默认 2.4，调高让低熵（复读）段更易触发温度回退，减少复读机
    '--prompt', WHISPER_PROMPT,
    '-otxt', '-oj', '-of', outBase,   // -oj 给出每段起止毫秒，说话人标注要用
  ];
}

// 折叠 whisper 复读机幻觉：嘈杂/静音段会输出 "是，是，是…" 或整句复读，
// 段级去重抓不到行内重复，这里按字符级把连续重复的短语折叠掉。
function collapseRepeats(text) {
  if (!text) return text;
  return text
    // 4–40 字短语连续重复 ≥3 次 → 只留 1 份（句级复读，几乎必为幻觉）
    .replace(/(.{4,40}?)\1{2,}/g, '$1')
    // 同一短语(2–8 汉字)带"可变结尾标点"重复 ≥3 次 → 留 1 份
    // （如"那个是，那个是。那个是…"——标点不一致会破坏上面整串回溯，单列一条兜住）
    .replace(/([一-龥]{2,8})([，。、！？～]?)(?:\1[，。、！？～]?){2,}/g, '$1$2')
    // 1–3 字碎片连续重复 ≥5 次 → 留 2 份（保留"对对对"这类自然强调，杀掉失控循环）
    .replace(/(.{1,3}?)\1{4,}/g, '$1$1');
}

// 转录单段音频：FFmpeg 转 WAV + Whisper 识别 + OpenCC 简化
// 返回 { text, duration }
async function transcribeChunk(inputPath, chunkId, opts = {}, sendEvent = null) {
  const wavPath = path.join('/tmp', `${chunkId}.wav`);
  const txtPath = path.join('/tmp', `${chunkId}.txt`);
  const jsonPath = path.join('/tmp', `${chunkId}.json`);
  let diarPromise = null;

  try {
    // FFmpeg 转换
    await execFileAsync('ffmpeg', [
      '-i', inputPath, '-ar', '16000', '-ac', '1',
      '-c:a', 'pcm_s16le', wavPath, '-y', '-loglevel', 'warning'
    ], { timeout: 300000 });

    // 获取时长（可选）
    let duration = 0;
    if (opts.getDuration) {
      try {
        const { stdout } = await execFileAsync('ffprobe', [
          '-i', wavPath, '-show_entries', 'format=duration',
          '-v', 'quiet', '-of', 'csv=p=0'
        ], { encoding: 'utf8', timeout: 10000 });
        duration = Math.round(parseFloat(stdout.trim())) || 0;
      } catch (e) {}
    }

    // 通知转码完成（带时长），让前端可以预估转录时间
    if (opts.onConvertDone) opts.onConvertDone(duration);

    // Whisper 转录（通过信号量串行化）
    // turbo + VAD 后单段处理快很多，外层切片放大到 10 分钟以减少 ffmpeg/prompt 复载开销
    // VAD 在每段内部做静音裁剪和智能切句，外层切片仅用于进度反馈和故障隔离
    const SEGMENT_SEC = 600; // 10分钟一段
    let rawText = '';
    const segments = [];          // 带时间戳的段落，说话人标注用
    // 说话人分离和 whisper 互不依赖（一个吃 CPU、一个吃神经引擎），整条一次性做，
    // 保证长音频分段转录时说话人编号在全片一致
    diarPromise = opts.diarize && DIAR_ENABLED ? diarizeAudio(wavPath) : null;

    await whisperSemaphore.acquire();
    try {
      const threads = opts.threads || os.cpus().length;

      if (duration > SEGMENT_SEC) {
        // 长音频：分段识别
        const segCount = Math.ceil(duration / SEGMENT_SEC);
        console.log(`[whisper] 长音频 ${duration}s，切成 ${segCount} 段分别识别`);
        const segTexts = [];

        for (let i = 0; i < segCount; i++) {
          // 发送分段进度事件（保活 SSE + 显示进度）
          if (sendEvent) {
            sendEvent('progress', {
              step: 'transcribe_segment',
              message: `正在识别第 ${i + 1}/${segCount} 段...`,
              current: i + 1,
              total: segCount,
            });
          }
          const segStart = i * SEGMENT_SEC;
          const segId = `${chunkId}_seg${i}`;
          const segWav = `/tmp/${segId}.wav`;
          const segTxt = `/tmp/${segId}.txt`;

          // 切出片段
          await execFileAsync('ffmpeg', [
            '-i', wavPath, '-ss', String(segStart), '-t', String(SEGMENT_SEC),
            '-c:a', 'pcm_s16le', segWav, '-y', '-loglevel', 'warning'
          ], { timeout: 60000 });

          // 识别片段
          try {
            await execFileAsync(WHISPER_BIN,
              buildWhisperArgs(segWav, `/tmp/${segId}`, threads),
              { timeout: 900000 }); // 每段最多 15 分钟（10min 段 + 余量）
          } catch (whisperErr) {
            if (whisperErr.code === 'ENOENT') throw new Error('whisper-cli 未安装或不在 PATH 中，请先安装 whisper-cpp');
            if (whisperErr.code === 'ENOENT' || (whisperErr.message && whisperErr.message.includes(MODEL_PATH))) throw new Error(`Whisper 模型文件未找到: ${MODEL_PATH}`);
            throw whisperErr;
          }

          if (fs.existsSync(segTxt)) {
            const segText = fs.readFileSync(segTxt, 'utf8').trim();
            // 简单幻觉检测：如果同一句话重复3次以上，丢弃这段
            const lines = segText.split('\n').filter(l => l.trim());
            const uniqueLines = new Set(lines);
            if (uniqueLines.size <= 2 && lines.length > 4) {
              console.log(`[whisper] 第${i+1}段检测到幻觉，跳过`);
            } else {
              segTexts.push(segText);
              segments.push(...readWhisperSegments(`/tmp/${segId}.json`, segStart * 1000));
            }
          }

          // 清理临时文件
          try { fs.unlinkSync(segWav); } catch (e) {}
          try { fs.unlinkSync(segTxt); } catch (e) {}
          try { fs.unlinkSync(`/tmp/${segId}.json`); } catch (e) {}
        }

        rawText = segTexts.join('\n');
      } else {
        // 短音频：整段识别
        try {
          await execFileAsync(WHISPER_BIN,
            buildWhisperArgs(wavPath, `/tmp/${chunkId}`, threads),
            { timeout: 1800000 });
        } catch (whisperErr) {
          if (whisperErr.code === 'ENOENT') throw new Error('whisper-cli 未安装或不在 PATH 中，请先安装 whisper-cpp');
          throw whisperErr;
        }

        if (fs.existsSync(txtPath)) {
          rawText = fs.readFileSync(txtPath, 'utf8').trim();
        }
        segments.push(...readWhisperSegments(jsonPath));
      }
    } finally {
      whisperSemaphore.release();
    }
    // 幻觉过滤：whisper 在音乐 / 静音段会吐出「请不吝点赞…明镜与点点栏目」这类训练数据里的字幕
    // （2026-09-20 在真实会议记录里整段刷屏）。过滤后的段落是唯一真相源：转录正文和说话人视图都从它拼
    const { segments: cleanSegments, dropped: halluDropped } = filterHallucinations(segments);
    if (halluDropped > 0) console.log(`[whisper] 过滤幻觉/复读段 ${halluDropped} 段`);
    // 纠错词表每次现读：改了词表，下一次转录就生效
    const corrections = loadCorrections(CORRECTIONS_FILE);
    const fixedSegments = cleanSegments.map(x => ({ ...x, text: applyCorrections(x.text, corrections) }));
    // 只有 JSON 意外缺失（一段都没读到）才退回旧的 txt 通道。段落全被当幻觉滤掉（整段只有音乐 / 静音）时
    // txt 里也全是幻觉，退回去就把「请不吝点赞…」存下来了——此时就该是空的
    const text = segments.length
      ? fixedSegments.map(x => x.text).join('\n')
      : applyCorrections(collapseRepeats(toSimplified(rawText)), corrections);
    // 不在这里 await diarPromise：调用方要先把转录落盘（铁律「转录一完成立即落盘」），
    // 评审实测过：在这里等分离，转录会有几分钟只活在内存里，node 一死整场全丢
    return { text, duration, segments: fixedSegments, diarPromise };
  } finally {
    // 清理临时文件；wav 要等说话人分离读完才能删（分离和转录并行，可能还在读）
    [txtPath, jsonPath].forEach(f => { try { fs.unlinkSync(f); } catch (e) {} });
    if (diarPromise) diarPromise.catch(() => null).then(() => { try { fs.unlinkSync(wavPath); } catch (e) {} });
    else { try { fs.unlinkSync(wavPath); } catch (e) {} }
  }
}

// ────── 边录边转 Session 管理 ──────

const liveSessions = new Map();

// 每 30 分钟清理过期 session（2 小时）
setInterval(() => {
  const now = Date.now();
  for (const [id, session] of liveSessions) {
    if (now - session.createdAt > 2 * 60 * 60 * 1000) {
      liveSessions.delete(id);
      console.log(`[live] 清理过期 session: ${id}`);
    }
  }
}, 30 * 60 * 1000);

// ────── API 端点 ──────

// SSE：上传录音 → 本地转录 → 本机说话人分离
app.post('/api/transcribe', upload.single('audio'), async (req, res) => {
  if (!req.file) return res.status(400).json({ error: '请上传音频文件' });

  const { sendEvent, end } = openSSE(req, res);

  const inputPath = req.file.path;
  const originalName = Buffer.from(req.file.originalname, 'latin1').toString('utf8');
  const id = newRecordId();

  try {
    // Step 1: 转码
    sendEvent('progress', { step: 'convert', message: '正在转换音频格式...' });

    const { text: rawTranscript, duration, segments, diarPromise } = await transcribeChunk(inputPath, id, {
      getDuration: true,
      diarize: true,
      onConvertDone: (dur) => {
        const durMsg = dur > 0
          ? `音频转换完成（${Math.floor(dur / 60)}分${dur % 60}秒）`
          : '音频转换完成';
        sendEvent('progress', { step: 'convert_done', message: durMsg, duration: dur });
        // Step 2: 转录开始（带时长，前端用于预估）
        sendEvent('progress', { step: 'transcribe', message: '正在本地语音识别（Metal 加速）...', duration: dur });
      },
    }, sendEvent);

    if (!rawTranscript) throw new Error('没有识别到说话内容（录音可能只有静音或音乐，也可能是音频格式有问题）');

    sendEvent('progress', {
      step: 'transcribe_done',
      message: `语音识别完成（${rawTranscript.length}字）`,
      transcript: rawTranscript,
    });

    // 转录一完成立即落盘，后续每阶段完成再 immutable 更新（见 saveTranscriptRecord）
    let record = {
      id,
      originalName,
      duration,
      timestamp: new Date().toISOString(),
      charCount: rawTranscript.length,
      transcript: rawTranscript,
      speakerTranscript: '',
    };
    saveTranscriptRecord(record);

    // 用本机说话人分离标出「说话人一 / 说话人二」，全程不联网。
    // 顺序有讲究：转录已在上面落盘，这里才等分离——分离最长可能再跑几分钟，期间转录已经安全
    let diarization = null;
    if (diarPromise) {
      sendEvent('progress', { step: 'speaker', message: '正在本机分离说话人（不调用云端）...' });
      diarization = await diarPromise;
    }
    // 密度门槛按「语音时长」算，不按全片时长——大半静音、中间有一段真实对话的长录音不该被误挡；
    // 绝对下限挡住只有几十个字的空录（那种录音做分离只会切出幻觉说话人）
    const speechMin = segments.reduce((a, x) => a + (x.t1 - x.t0), 0) / 60000;
    const tooSparse = rawTranscript.length < 100
      || (speechMin >= 1 && rawTranscript.length / speechMin < DIAR_MIN_CHARS_PER_MIN);
    // 说话人视图做语气词顺滑（Typeless 式，保守规则）；纯文字视图保持逐字原文
    const segsForSpeaker = segments.map(x => ({ ...x, text: smoothFillers(x.text) }));
    const spk = tooSparse ? null : buildSpeakerTranscript(segsForSpeaker, diarization);
    if (spk) {
      record = { ...record, speakerTranscript: spk.text };
      saveTranscriptRecord(record);
      sendEvent('speaker_chunk', { content: spk.text });     // 前端据此显示「显示说话人 / 纯文字」切换
      const pct = Math.round(100 * spk.uncertainChars / Math.max(spk.totalChars, 1));
      sendEvent('progress', { step: 'speaker_done', message: `说话人分离完成（${spk.speakers} 人${pct > 0 ? `，${pct}% 的内容拿不准、已标「说话人？」` : ''}）` });
    } else {
      // 分不出来的原因不一样，提示也要不一样，不然排障会被带偏（评审确认过三种情况都真实会发生）
      const message = !DIAR_ENABLED ? '说话人分离组件未安装，只出纯文字'
        : tooSparse ? '录音内容太少，跳过说话人分离'
        : diarization && diarization.skipped ? '录音几乎无声，跳过说话人分离'
        : !diarization ? '说话人分离失败，已回退纯文字'
        : '只识别到一个说话人';
      console.log(`[diar] 无说话人标注：${message}`);
      sendEvent('progress', { step: 'speaker_done', message });
    }

    sendEvent('complete', {
      id,
      originalName,
      duration,
      charCount: rawTranscript.length,
    });

    // 清理上传的原始文件（wav/txt 已在 transcribeChunk 中清理）
    try { fs.unlinkSync(inputPath); } catch (e) {}

  } catch (err) {
    const safeMsg = err.message.replace(/\/Users\/[^\s]*/g, '[path]');
    sendEvent('error', { message: safeMsg });
    try { fs.unlinkSync(inputPath); } catch (e) {}
  }

  end();
});

// 按顺序拼接 session 中已完成的 chunk 文本
function assembleSessionText(session) {
  // 遍历所有 chunk（不要求连续），跳过失败的，保留成功的
  const maxIdx = Math.max(...session.chunks.keys(), -1);
  const texts = [];
  for (let i = 0; i <= maxIdx; i++) {
    const chunk = session.chunks.get(i);
    if (chunk && chunk.status === 'done' && chunk.text) {
      texts.push(chunk.text);
    }
  }
  session.totalText = texts.join('\n');
  session.assembledUpTo = maxIdx;
}

// ────── 边录边转 API ──────

const liveUpload = multer({ dest: UPLOAD_DIR, limits: { fileSize: 50 * 1024 * 1024 } });

// 创建实时转录 session
app.post('/api/live/start', (req, res) => {
  const sessionId = newRecordId('live-');
  liveSessions.set(sessionId, {
    id: sessionId,
    createdAt: Date.now(),
    chunks: new Map(),          // index → { status, text }
    chunkPromises: new Map(),   // index → Promise（追踪进行中的转录）
    totalText: '',
    assembledUpTo: -1,
    finished: false,
  });
  console.log(`[live] 新 session: ${sessionId}`);
  res.json({ sessionId });
});

// 上传音频片段并转录
app.post('/api/live/chunk/:sessionId', liveUpload.single('chunk'), async (req, res) => {
  const session = liveSessions.get(req.params.sessionId);
  if (!session) return res.status(404).json({ error: 'Session 不存在' });
  if (session.finished) return res.status(409).json({ error: 'Session 已结束' });
  if (!req.file) return res.status(400).json({ error: '缺少音频数据' });

  const index = parseInt(req.query.index) || 0;
  const inputPath = req.file.path;
  const chunkId = `${session.id}_c${index}`;

  const { sendEvent, end } = openSSE(req, res);

  // 追踪这个 chunk 的转录 Promise（finish 端点需要等待）
  const chunkWork = (async () => {
    try {
      sendEvent('chunk_progress', { index, step: 'converting' });
      sendEvent('chunk_progress', { index, step: 'transcribing' });

      const { text } = await transcribeChunk(inputPath, chunkId);
      session.chunks.set(index, { status: 'done', text });
      assembleSessionText(session);

      console.log(`[live] chunk ${index} 完成，${text.length} 字，累计 ${session.totalText.length} 字`);
      sendEvent('chunk_done', { index, chars: text.length, totalChars: session.totalText.length });
    } catch (err) {
      session.chunks.set(index, { status: 'error', text: '' });
      console.error(`[live] chunk ${index} 失败:`, err.message);
      sendEvent('chunk_error', { index, error: err.message });
    } finally {
      try { fs.unlinkSync(inputPath); } catch (e) {}
      end();
    }
  })();
  session.chunkPromises.set(index, chunkWork);
  await chunkWork;
});

// 结束录音：转录最后一段 + 生成纪要
app.post('/api/live/finish/:sessionId', liveUpload.single('chunk'), async (req, res) => {
  const session = liveSessions.get(req.params.sessionId);
  if (!session) return res.status(404).json({ error: 'Session 不存在' });
  session.finished = true;

  const lastIndex = parseInt(req.query.index) || 0;
  const { sendEvent, end } = openSSE(req, res);

  try {
    // 等待所有正在进行中的 chunk 转录完成
    if (session.chunkPromises.size > 0) {
      sendEvent('progress', { step: 'waiting_chunks', message: '等待剩余片段转录完成...' });
      await Promise.allSettled([...session.chunkPromises.values()]);
    }

    // 转录最后一个 chunk（如果有）
    if (req.file) {
      const inputPath = req.file.path;
      const chunkId = `${session.id}_c${lastIndex}`;

      sendEvent('chunk_progress', { index: lastIndex, step: 'transcribing' });
      try {
        const { text } = await transcribeChunk(inputPath, chunkId);
        session.chunks.set(lastIndex, { status: 'done', text });
        sendEvent('chunk_done', { index: lastIndex, chars: text.length, totalChars: 0 });
      } catch (err) {
        session.chunks.set(lastIndex, { status: 'error', text: '' });
        sendEvent('chunk_error', { index: lastIndex, error: err.message });
      } finally {
        try { fs.unlinkSync(inputPath); } catch (e) {}
      }
    }

    // 按顺序拼接所有文本
    assembleSessionText(session);

    const rawTranscript = session.totalText;
    if (!rawTranscript) throw new Error('没有转录到任何文本');

    // 获取总时长（粗略估计：chunk 数 × 30 秒）
    const duration = (session.assembledUpTo + 1) * 30;
    const originalName = `会议录音_${new Date().toLocaleDateString('sv-SE', { timeZone: 'Asia/Shanghai' })}`;

    sendEvent('progress', {
      step: 'transcribe_done',
      message: `语音识别完成（${rawTranscript.length}字）`,
      transcript: rawTranscript,
    });

    // 转录一完成立即落盘，后续每阶段完成再 immutable 更新（见 saveTranscriptRecord）
    const id = newRecordId();
    let record = {
      id,
      originalName,
      duration,
      timestamp: new Date().toISOString(),
      charCount: rawTranscript.length,
      transcript: rawTranscript,
      speakerTranscript: '',
    };
    saveTranscriptRecord(record);

    sendEvent('complete', {
      id,
      originalName,
      duration,
      charCount: rawTranscript.length,
    });

    console.log(`[live] session ${session.id} 完成，${rawTranscript.length} 字`);
  } catch (err) {
    const safeMsg = err.message.replace(/\/Users\/[^\s]*/g, '[path]');
    sendEvent('error', { message: safeMsg });
  } finally {
    liveSessions.delete(session.id);
    end();
  }
});

// ────── 其他 API ──────

// 前端按它收起纪要相关的界面：只出原文
app.get('/api/config', (req, res) => {
  res.json({ transcriptOnly: true });
});

app.get('/api/history', async (req, res) => {
  try {
    const files = fs.readdirSync(TRANSCRIPT_DIR)
      .filter(f => f.endsWith('.json'))
      .sort()
      .reverse();

    const list = (await Promise.all(
      files.map(async f => {
        try {
          const raw = await fs.promises.readFile(path.join(TRANSCRIPT_DIR, f), 'utf8');
          const data = JSON.parse(raw);
          return {
            id: data.id,
            originalName: data.originalName,
            duration: data.duration,
            timestamp: data.timestamp,
            charCount: data.charCount,
            hasMinutes: !!data.minutes,
          };
        } catch (e) { return null; }
      })
    )).filter(Boolean);

    res.json(list);
  } catch (err) {
    res.json([]);
  }
});

// Get transcript detail — P0 fix: validate ID
app.get('/api/transcript/:id', (req, res) => {
  const filePath = safeTranscriptPath(req.params.id);
  if (!filePath) return res.status(400).json({ error: 'ID 格式无效' });
  if (!fs.existsSync(filePath)) return res.status(404).json({ error: '未找到' });
  try {
    const data = JSON.parse(fs.readFileSync(filePath, 'utf8'));
    res.json(data);
  } catch (err) {
    res.status(500).json({ error: '读取失败' });
  }
});

// Delete transcript — P0 fix: validate ID
app.delete('/api/transcript/:id', (req, res) => {
  const filePath = safeTranscriptPath(req.params.id);
  if (!filePath) return res.status(400).json({ error: 'ID 格式无效' });
  try {
    fs.unlinkSync(filePath);
    res.json({ ok: true });
  } catch (err) {
    if (err.code === 'ENOENT') res.status(404).json({ error: '未找到' });
    else res.status(500).json({ error: '删除失败' });
  }
});

const http = require('http');
const https = require('https');
// 只给这台 Mac 自己用：接口没有登录，听所有网卡的话，同一 Wi-Fi 下的设备能列出、读取、删除转录记录
const LISTEN_HOST = '127.0.0.1';
const SHOWN_HOST = 'localhost';

// 证书目录：.app 启动时通过 CERTS_DIR 指到 ~/Library/Application Support/留声/certs
const CERTS_DIR = process.env.CERTS_DIR || path.join(__dirname, 'certs');
const sslOptions = {
  key: fs.readFileSync(path.join(CERTS_DIR, 'key.pem')),
  cert: fs.readFileSync(path.join(CERTS_DIR, 'cert.pem')),
};

// 手机/其他设备要信任的根证书。.app 启动时由 launcher 用 mkcert 现场生成 CA 并通过 ROOT_CA_PEM
// 指过来；开发模式回退到 public/rootCA.pem（需手动从 `mkcert -CAROOT` 拷入）
const ROOT_CA_PEM = process.env.ROOT_CA_PEM || path.join(__dirname, 'public', 'rootCA.pem');

// Setup page app (HTTP only)
const setupApp = express();
setupApp.use('/rootCA.pem', (req, res) => {
  res.download(ROOT_CA_PEM, 'liusheng-ca.pem');
});
// Windows 需要 .crt 扩展名才能双击识别
setupApp.use('/rootCA.crt', (req, res) => {
  res.download(ROOT_CA_PEM, 'rootCA.crt');
});
// 手机「描述文件 / 证书信任设置」里显示的是 CA 的 CN。mkcert 按「用户@主机名」命名，每台机器都不一样，
// 设置页的 iPhone 图示从这里读真实名字填进去，别写死
setupApp.get('/ca-name', (req, res) => {
  try {
    const { subject } = new crypto.X509Certificate(fs.readFileSync(ROOT_CA_PEM));
    const cn = (subject.match(/^CN=(.*)$/m) || [])[1] || '';
    if (!cn) return res.status(404).json({ error: '根证书没有 CN' });
    // iOS 描述文件列表会把「(用户名)」这种括号后缀折到第二行显示，图示也拆成两行
    const idx = cn.lastIndexOf(' (');
    res.json({ name: cn, main: idx > 0 ? cn.slice(0, idx) : cn, suffix: idx > 0 ? cn.slice(idx + 1) : '' });
  } catch (err) {
    res.status(404).json({ error: '未找到根证书' });
  }
});
setupApp.get('*', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'setup.html'));
});

// HTTP:3000 - certificate setup page
http.createServer(setupApp).listen(PORT, LISTEN_HOST);

// HTTPS:3443 - main app
// 关闭所有内置超时，防止长音频（60分钟+）转录时 SSE 连接被服务端切断
const httpsServer = https.createServer(sslOptions, app);
httpsServer.timeout = 0;           // socket 空闲超时：禁用
httpsServer.keepAliveTimeout = 0;  // keep-alive 超时：禁用
httpsServer.headersTimeout = 0;    // 请求头超时：禁用（Node 18+ 默认 60s）
httpsServer.requestTimeout = 0;    // 请求体超时：禁用（Node 18+ 默认 300s）
const HTTPS_PORT = parseInt(process.env.HTTPS_PORT || '3443', 10);
httpsServer.listen(HTTPS_PORT, LISTEN_HOST);

// 证书热加载：.app 的 launcher 发现局域网 IP 变了会重签证书（服务在跑时也会），这里轮询文件变化，
// 用 setSecureContext 换上新证书——不用重启进程，不打断正在进行的转录。
// mkcert 先写 cert 再写 key，两个文件都盯着，最后一次变化后再等 1 秒才读，避免读到一新一旧
const CERT_POLL_MS = 5000;
const CERT_RELOAD_DEBOUNCE_MS = 1000;
let certReloadTimer = null;
function reloadCerts() {
  try {
    httpsServer.setSecureContext({
      key: fs.readFileSync(path.join(CERTS_DIR, 'key.pem')),
      cert: fs.readFileSync(path.join(CERTS_DIR, 'cert.pem')),
    });
    console.log('[certs] 证书已更新，热加载完成');
  } catch (err) {
    console.error('[certs] 证书热加载失败，继续用旧证书:', err.message);
  }
}
for (const name of ['key.pem', 'cert.pem']) {
  fs.watchFile(path.join(CERTS_DIR, name), { interval: CERT_POLL_MS }, (curr, prev) => {
    if (curr.mtimeMs === prev.mtimeMs) return;
    clearTimeout(certReloadTimer);
    certReloadTimer = setTimeout(reloadCerts, CERT_RELOAD_DEBOUNCE_MS);
  });
}

console.log('');
console.log('==========================================');
console.log('  留声 已启动');
console.log('  本地转录：录音和文字都不出这台电脑');
console.log('==========================================');
console.log(`  首次设置:  http://${SHOWN_HOST}:${PORT}`);
console.log(`  正式使用:  https://${SHOWN_HOST}:${HTTPS_PORT}`);
console.log('==========================================');
console.log('');
