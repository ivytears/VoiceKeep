#!/usr/bin/env python3
"""本地说话人分离（sherpa-onnx）。全程离线，音频不出本机。

用法:
    ~/.diar-venv/bin/python tools/diarize.py <audio> [--num N] [--threshold T] [--threads N] [--raw]

输出 (stdout, JSON):
    {"speakers": 2, "segments": [{"start": 0.0, "end": 6.0, "speaker": 0}, ...]}
    或 {"speakers": 0, "segments": [], "skipped": "too_quiet"}   # 录音太轻，做分离只会切出幻觉说话人

    - speaker 已按「首次出现顺序」重编号为 0..N-1（sherpa-onnx 原始 cluster id 不连续，实测是 0,1,2,3,4,6,8,9,11,12）
    - segments 按 start 升序，但**区间之间可能互相重叠**，不是严格的时间分区
      → 和 whisper 段落合并时必须「按重叠时长投票」，用中点归属或区间查找会错（实测 24 个区间有 10 对重叠）
    - --num N 指定人数：先自动聚类，再按簇心声纹相似度合并到 N（不用 sherpa 的强制 k：
      实测强制 k=2 会把两个真人合进一个簇，比多切更致命）

两级聚类（2026-09-20 评审后定稿）：
    第一级 sherpa FastClustering（threshold 0.60）出原始簇——远场录音上会多切（一个人拆成几个簇）。
    第二级用 CAM++ 给每个簇算声纹簇心，凝聚合并：相似度 ≥ CENTROID_MERGE_COS 的簇心并成一个人；
    小簇（< max(5 秒, 5%)）**并入声纹最近的大簇，绝不丢弃**——旧版直接丢，实测丢掉 13.5%~57.8% 的
    语音，制造大面积声纹空洞，空洞里的字全靠"继承上一句"猜，是张冠李戴的主要来源。
    音量闸 -55 dB（只挡数字静音；空录靠调用方的转录密度门槛，见 server.js DIAR_MIN_CHARS_PER_MIN）

依赖: 只有 sherpa-onnx（~/.diar-venv）。不需要 numpy / torch。音频解码走 ffmpeg 子进程。
模型: ~/.diar-models（pyannote-segmentation-3.0 + 3D-Speaker CAM++ 中文），来自 k2-fsa/sherpa-onnx 官方 release。
"""
import array
import json
import os
import re
import subprocess
import sys

import sherpa_onnx

# ---- 需要按录音环境校准的参数，全部集中在这里 ----
DEFAULT_THRESHOLD = 0.60   # 越小切出的人越多；官方默认 0.5 对中文偏碎
MIN_DURATION_ON = 0.3      # 短于此的语音段丢弃（秒）
MIN_DURATION_OFF = 0.5     # 短于此的静音不算断句（秒）
SMALL_MIN_ABS_SEC = 5.0    # 小簇门槛：总说话时长低于 max(5 秒, 5%) 的簇不独立成人，并入声纹最近的大簇
SMALL_MIN_SHARE = 0.05
CENTROID_MERGE_COS = 0.60  # 二级合并：簇心余弦相似度高于此值就是同一个人（实测跨人 0.25~0.28）
CENTROID_MAX_SEC = 20.0    # 每个簇最多取这么多秒的最长片段来算簇心（够稳又省时）
MIN_MEAN_VOLUME_DB = -55.0 # 音量闸：只挡真正的静音文件。
#   实测教训：-40 dB 会误杀真实录音——手机放桌上远场录的面试（-44.3 dB）、1 对 1 谈话（-42.1 dB）
#   都是正常对话却被挡掉。真正该挡的「空录」由调用方按转录密度判断（每分钟字数），音量分不开这两者
DEFAULT_THREADS = 4        # 实测 4 最优，8 反而更慢

MODEL_DIR = os.environ.get('LIUSHENG_DIAR_MODELS', os.path.expanduser('~/.diar-models'))
SEG_MODEL = os.path.join(MODEL_DIR, 'sherpa-onnx-pyannote-segmentation-3-0', 'model.onnx')
EMB_MODEL = os.path.join(MODEL_DIR, '3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx')
import shutil as _shutil
# 优先 PATH（打包的 .app 里 launcher 把包内 ffmpeg 排最前；开发版 PATH 里是 brew 的），再兜底 brew 绝对路径
FFMPEG = os.environ.get('LIUSHENG_FFMPEG') or _shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg'


def mean_volume_db(path):
    """整体平均电平（dBFS）。读不出来返回 None（当作没问题，继续分离）。"""
    p = subprocess.run([FFMPEG, '-nostdin', '-hide_banner', '-i', path, '-af', 'volumedetect',
                        '-f', 'null', '-'], capture_output=True, text=True)
    m = re.search(r'mean_volume:\s*(-?[\d.]+) dB', p.stderr)
    return float(m.group(1)) if m else None


def load_16k_mono(path):
    """任意格式 → 16kHz 单声道 float32。返回 array.array('f')，不依赖 numpy。"""
    proc = subprocess.run(
        [FFMPEG, '-nostdin', '-hide_banner', '-loglevel', 'error',
         '-i', path, '-f', 'f32le', '-ac', '1', '-ar', '16000', '-'],
        check=True, stdout=subprocess.PIPE)
    samples = array.array('f')
    samples.frombytes(proc.stdout)
    return samples


def build(num_speakers=-1, threshold=DEFAULT_THRESHOLD, num_threads=DEFAULT_THREADS):
    for p in (SEG_MODEL, EMB_MODEL):
        if not os.path.exists(p):
            raise RuntimeError('模型缺失: %s' % p)
    cfg = sherpa_onnx.OfflineSpeakerDiarizationConfig(
        segmentation=sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
            pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(model=SEG_MODEL),
            num_threads=num_threads, provider='cpu'),   # CoreML 实测更慢，保持 cpu
        embedding=sherpa_onnx.SpeakerEmbeddingExtractorConfig(
            model=EMB_MODEL, num_threads=num_threads, provider='cpu'),
        clustering=sherpa_onnx.FastClusteringConfig(
            num_clusters=num_speakers, threshold=threshold),   # -1 = 自动估人数
        min_duration_on=MIN_DURATION_ON,
        min_duration_off=MIN_DURATION_OFF,
    )
    if not cfg.validate():
        raise RuntimeError('OfflineSpeakerDiarizationConfig 校验失败')
    return sherpa_onnx.OfflineSpeakerDiarization(cfg)


def _cos(a, b):
    dot = sum(x * y for x, y in zip(a, b))
    na = sum(x * x for x in a) ** 0.5
    nb = sum(y * y for y in b) ** 0.5
    return dot / (na * nb) if na and nb else 0.0


def _centroids(audio, items, num_threads=DEFAULT_THREADS):
    """给每个原始簇算声纹簇心：取该簇最长的几段（合计 ≤ CENTROID_MAX_SEC），CAM++ 提向量按时长加权平均。"""
    ex = sherpa_onnx.SpeakerEmbeddingExtractor(sherpa_onnx.SpeakerEmbeddingExtractorConfig(
        model=EMB_MODEL, num_threads=num_threads, provider='cpu'))
    by = {}
    for seg in items:
        by.setdefault(seg['speaker'], []).append(seg)
    cents = {}
    for spk, segs in by.items():
        segs = sorted(segs, key=lambda x: x['end'] - x['start'], reverse=True)
        acc, total = None, 0.0
        for seg in segs:
            dur = seg['end'] - seg['start']
            if dur < 0.5 and total > 0:
                continue                      # 有料了就不要碎渣
            i0, i1 = int(seg['start'] * 16000), int(seg['end'] * 16000)
            chunk = audio[i0:i1]
            if len(chunk) < 1600:
                continue
            st = ex.create_stream()
            st.accept_waveform(16000, chunk)
            st.input_finished()
            emb = list(ex.compute(st))
            acc = [dur * v for v in emb] if acc is None else [a + dur * v for a, v in zip(acc, emb)]
            total += dur
            if total >= CENTROID_MAX_SEC:
                break
        if acc is not None:
            cents[spk] = [v / total for v in acc]
    return cents


def _merge_clusters(audio, items, num_speakers=-1, num_threads=DEFAULT_THREADS):
    """二级合并：簇心相似的簇并成一个人；小簇并入声纹最近的大簇（绝不丢段落）。
    num_speakers>0 时合并到恰好 N 个。返回改写了 speaker 的 segments。"""
    total_dur = {}
    for seg in items:
        total_dur[seg['speaker']] = total_dur.get(seg['speaker'], 0.0) + (seg['end'] - seg['start'])
    if len(total_dur) <= 1:
        return items
    cents = _centroids(audio, items, num_threads)
    remap = {}
    anchor = max(total_dur, key=total_dur.get)
    for spk in total_dur:
        if spk not in cents:
            remap[spk] = anchor               # 全是碎渣算不出簇心的簇：并给最大簇
    groups = {spk: {'members': [spk], 'cent': c, 'dur': total_dur[spk]} for spk, c in cents.items()}

    def merge_once(threshold):
        best, pair = -1.0, None
        keys = list(groups)
        for i in range(len(keys)):
            for j in range(i + 1, len(keys)):
                c = _cos(groups[keys[i]]['cent'], groups[keys[j]]['cent'])
                if c > best:
                    best, pair = c, (keys[i], keys[j])
        if pair is None or best < threshold:
            return False
        a, b = pair
        if groups[a]['dur'] < groups[b]['dur']:
            a, b = b, a                        # 编号留给大的
        wa, wb = groups[a]['dur'], groups[b]['dur']
        groups[a]['cent'] = [(wa * x + wb * y) / (wa + wb) for x, y in zip(groups[a]['cent'], groups[b]['cent'])]
        groups[a]['members'] += groups[b]['members']
        groups[a]['dur'] += wb
        del groups[b]
        return True

    if num_speakers and num_speakers > 0:
        while len(groups) > num_speakers and merge_once(-1.0):
            pass
    else:
        while len(groups) > 1 and merge_once(CENTROID_MERGE_COS):
            pass
        speech = sum(g['dur'] for g in groups.values())
        floor = max(SMALL_MIN_ABS_SEC, speech * SMALL_MIN_SHARE)
        while len(groups) > 1:                 # 小簇并入声纹最近的大簇，绝不丢
            small = [k for k, g in groups.items() if g['dur'] < floor]
            if not small:
                break
            k = min(small, key=lambda x: groups[x]['dur'])
            big = [x for x in groups if x != k]
            target = max(big, key=lambda x: _cos(groups[k]['cent'], groups[x]['cent']))
            wa, wb = groups[target]['dur'], groups[k]['dur']
            groups[target]['cent'] = [(wa * x + wb * y) / (wa + wb) for x, y in
                                      zip(groups[target]['cent'], groups[k]['cent'])]
            groups[target]['members'] += groups[k]['members']
            groups[target]['dur'] += wb
            del groups[k]
    for root, g in groups.items():
        for m in g['members']:
            remap[m] = root
    for spk, tgt in list(remap.items()):       # 兜底簇跟着它的锚点走到最终归属
        while tgt in remap and remap[tgt] != tgt:
            tgt = remap[tgt]
        remap[spk] = tgt
    return [{**seg, 'speaker': remap.get(seg['speaker'], seg['speaker'])} for seg in items]


def diarize(path, num_speakers=-1, threshold=DEFAULT_THRESHOLD,
            num_threads=DEFAULT_THREADS, raw=False, skip_volume_gate=False):
    if not skip_volume_gate:
        vol = mean_volume_db(path)
        if vol is not None and vol < MIN_MEAN_VOLUME_DB:
            return {'speakers': 0, 'segments': [], 'skipped': 'too_quiet', 'mean_volume_db': vol}
    # 第一级永远自动聚类（num_clusters=-1）：sherpa 的强制 k 实测会把两个真人合进一簇
    sd = build(-1, threshold, num_threads)
    audio = load_16k_mono(path)
    segs = sd.process(audio).sort_by_start_time()
    items = [{'start': round(s.start, 3), 'end': round(s.end, 3), 'speaker': s.speaker} for s in segs]
    raw_clusters = len({i['speaker'] for i in items})
    if raw:
        return {'speakers': raw_clusters, 'segments': items}
    items = _merge_clusters(audio, items, num_speakers, num_threads)
    remap = {}                          # 按首次出现顺序重编号
    for s in items:
        if s['speaker'] not in remap:
            remap[s['speaker']] = len(remap)
        s['speaker'] = remap[s['speaker']]
    return {'speakers': len(remap), 'raw_clusters': raw_clusters, 'segments': items}


def _arg(argv, flag, cast, default):
    return cast(argv[argv.index(flag) + 1]) if flag in argv else default


if __name__ == '__main__':
    argv = sys.argv[1:]
    if not argv:
        sys.exit(__doc__)
    json.dump(diarize(argv[0],
                      num_speakers=_arg(argv, '--num', int, -1),
                      threshold=_arg(argv, '--threshold', float, DEFAULT_THRESHOLD),
                      num_threads=_arg(argv, '--threads', int, DEFAULT_THREADS),
                      raw='--raw' in argv,
                      skip_volume_gate='--no-volume-gate' in argv),
              sys.stdout, ensure_ascii=False)
    sys.stdout.write('\n')
