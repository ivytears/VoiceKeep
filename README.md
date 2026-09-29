# 留声 VoiceKeep

在 Mac 上把录音转成文字。**录音和文字都不离开你的电脑。**

把会议、访谈、面试的录音拖进去，几分钟后拿到带标点的逐字稿，还能自动标出「说话人一 / 说话人二」。

## 能做什么

- **本地语音识别**：用 whisper large-v3-turbo 模型，中文为主、夹着英文也能认，用 Mac 的 GPU 加速。
- **标出谁在说话**：本机声纹分离，自动标「说话人一 / 说话人二」，拿不准的地方标「说话人？」（可选组件，见下文）。
- **干净的原文**：去掉 whisper 在静音、音乐段编出来的字幕幻觉（「请不吝点赞…」这类）；「显示说话人」视图里顺滑口头语气词。
- **纠错词表**：总认错的专有名词（比如把 Claude Code 写成 Cloud Code）按表自动改对，你可以自己往里加。
- **两种用法**：上传录音文件（iPhone 语音备忘录导出的 m4a 等 8 种格式都行），或者直接在网页里录。

## 隐私

- 语音识别和说话人分离都在你的 Mac 上完成。没有任何云端 AI，没有账号，没有统计。
- 服务只监听本机（127.0.0.1），同一 Wi-Fi 下的其他设备连不上。
- 转录记录只保留 24 小时，到时自动删除；想留的文字请及时复制出去。

## 安装

要求：Apple 芯片（M1 及以后）的 Mac，macOS 15 或更新，约 2 GB 空闲空间。

1. 到 [Releases](../../releases) 下载最新版的 `VoiceKeep-版本号.dmg`，双击打开，把「留声」拖进「应用程序」。
2. 打开「应用程序」，双击「留声」。第一次会提示「Apple 无法验证…」：点「完成」，然后打开「系统设置 → 隐私与安全性」，拉到最下面点「仍要打开」，再确认一次。（留声没有做苹果开发者签名，所以需要这一步，只做一次。）
3. 接着会请你输入一次本机登录密码，用来信任留声在本机生成的 HTTPS 证书，也只做一次。之后浏览器会自动打开 `https://localhost:3443`。

**可选：标出说话人。** 打开「终端」，运行下面这一行（第一次用 `python3` 时 macOS 可能提示安装命令行开发者工具，同意即可）：

```bash
python3 -m venv ~/.diar-venv && ~/.diar-venv/bin/pip install "sherpa-onnx>=1.13"
```

装好后重新打开留声，转录结果就会带说话人。不装也能正常用，只是只出纯文字。

## 日常使用

- 双击「留声」就是打开网页；服务已经在后台运行的话，只会再开一次网页。
- 把录音文件拖进网页，或者点麦克风直接录。
- 结果页右上角可以在「显示说话人」和「纯文字」之间切换。
- 纠错词表在 `~/Library/Application Support/留声/data/纠错词表.txt`，每行写「错词 => 正词」，改完下一次转录就生效。
- 想彻底退出：打开「活动监视器」，搜索 `node`，结束这个进程。
- 装新版之前，先按上一条退出旧版，否则打开的还是旧版。

## 从源码构建

需要 Apple 芯片的 Mac、Xcode 命令行工具和 [Homebrew](https://brew.sh)。

```bash
brew install node ffmpeg whisper-cpp ggml
npm install
```

语音识别模型放在 `~/.whisper-models`：

- https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q8_0.bin
- https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin

说话人分离模型放在 `~/.diar-models`（第一个需要解压）：

- https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2
- https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx

常用命令：

- 开发运行：`./start.sh`（证书的准备见 [CLAUDE.md](CLAUDE.md)）
- 测试：`node tools/speakers.test.js && node tools/corrections.test.js && ./tests/server-test.sh`
- 打包：`./packaging/build.sh`，产物在 `packaging/dist/留声.dmg`，打完会自动跑启动测试和沙盒冒烟测试

架构说明和踩过的坑都在 [CLAUDE.md](CLAUDE.md)。

## 许可证

MIT，见 [LICENSE](LICENSE)。安装包里打包的第三方组件和模型见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
