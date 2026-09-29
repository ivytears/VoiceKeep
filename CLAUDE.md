# 留声 开发指南

> 给开发者和 AI 编程助手看的：架构、约定和踩过的坑。给用户的说明见 [README.md](README.md)。

## 架构

- **后端**：单文件 `server.js`（Node.js + Express），运行时依赖只有 express / multer / opencc-js。**前端**：`public/index.html`，单文件原生 JS，没有构建步骤。
- **端口**：HTTPS 3443 是主应用；HTTP 3000 是证书引导页（`public/setup.html`，提供本机 CA 下载）。两个都**只监听 127.0.0.1**：接口没有登录，对局域网开放就等于同一 Wi-Fi 的设备能列出、读取、删除转录记录。
- **两条录入路径**（都是 SSE）：整段上传 `POST /api/transcribe`；边录边转 `POST /api/live/{start,chunk/:id,finish/:id}`，前端每 30 秒传一片。拖进来的文件（可以多个、可以整个文件夹）在前端排队，一个转完再传下一个；转录队列和边录边转共用一个进度页，同一时间只允许一件在跑。
- **音频**：FFmpeg 转成 16k 单声道 WAV；超过 10 分钟按 600 秒切片顺序识别；whisper 并发数为 1。
- **语音识别**：whisper.cpp，模型 `large-v3-turbo-q8_0`（没有就退回 q5_0）+ Silero VAD + 束搜索 `-bs 5`，initial prompt 是一句中性的中文开场白（让输出带标点）。默认用 PATH 上的 whisper-cli（Homebrew，Metal）；环境变量 `WHISPER_CLI` 指向自编译的 CoreML 版可以用上 Apple 神经引擎（整体快约 2.4 倍）。
- **文本处理**（`tools/`）：`textclean.js` 用黑名单删字幕幻觉、删连续复读，并给说话人视图做保守的语气词顺滑（纯文字视图保持逐字原文）；`corrections.js` 是纠错词表（数据目录里的 `纠错词表.txt`，没有就写入默认表，每次转录现读）；繁转简用 opencc-js。
- **说话人分离**：`tools/diarize.py` 跑 sherpa-onnx（`~/.diar-venv`，离线；模型在 `~/.diar-models`，安装包里带一份），输出 `{speakers, segments}`；`tools/speakers.js` 把说话区间和 whisper 段落按重叠时长合并成「[说话人一] …」。没装 `~/.diar-venv` 就只出纯文字。
- **数据**：记录 JSON 在 `transcripts/`，上传临时文件在 `uploads/`（数据目录默认是项目根，安装包里是 `~/Library/Application Support/留声/data`）。启动时和每小时清理超过 24 小时的文件。
- **打包**：`packaging/build.sh` 产出自包含的 `留声.app` 和 `.dmg`：官方 Node.js、从源码编译的 arm64 FFmpeg（`build-ffmpeg.sh`，只含解码器、不启用 GPL 组件）、从 Homebrew 抽出并重定位的 whisper-cli 和 dylib、模型、说话人分离模型。`packaging/launcher.sh` 是 .app 的主程序：清隔离标记，按本机名和局域网 IP 签发 / 重签证书，首次以当前用户身份信任本地 CA，已在运行就只开浏览器，否则把 node 放到后台、等端口就绪、开完浏览器就退出。

## 开发与测试

- **开发运行**：`./start.sh`。有 CoreML 版 whisper（`~/.whisper-build/whisper.cpp/build/bin/whisper-cli`）就用它。证书：本机装过安装版就复用它那套已被信任的证书；否则自己用 mkcert 准备：
  ```bash
  mkcert -install
  mkdir -p certs && mkcert -cert-file certs/cert.pem -key-file certs/key.pem localhost 127.0.0.1 ::1
  ROOT_CA_PEM="$(mkcert -CAROOT)/rootCA.pem" ./start.sh
  ```
- **单元测试**：`node tools/speakers.test.js`、`node tools/corrections.test.js`。
- **服务流程测试**：`./tests/server-test.sh`。whisper 和说话人分离换成桩，验证只听本机、没有云端接口、两条路径落盘、纠错词表现改现生效、说话人标注不丢字、整段幻觉不落盘。
- **打包测试**：`./packaging/build.sh` 最后自动跑 `launcher-test.sh`（把 security / osascript 换成桩，测首次启动和证书流程）和 `smoke-test.sh`（用 `sandbox-exec` 拒读 Homebrew 目录，验证安装包真的自包含）。

## 必须守住的

- **转录一出来就先落盘**，再做后续：说话人分离可能再跑几分钟，这段时间里转录必须已经安全。
- **SSE 端点都走 `openSSE(req, res)`**：每 15 秒发一行心跳保活；客户端断线后服务端继续跑完并落盘。新加 SSE 端点别再手写 `res.writeHead` + `res.write`。
- **说话人标注是附加产物**：任何失败都回退纯文字，绝不影响转录。
- **不调用任何云端服务，只监听本机。**

## 踩过的坑

- **whisper 在静音 / 音乐段会吐出训练数据里的字幕**（「请不吝点赞 订阅 转发 打赏支持明镜与点点栏目」最典型），按黑名单整段删。段落全被滤掉时不能退回 txt 通道，txt 里也全是幻觉，此时应报「没有识别到说话内容」。
- **专有名词别往 initial prompt 里塞**：实测写了照样认错，还会把别处改错。专有名词只走纠错词表。
- **说话人分离**：sherpa-onnx 返回的 cluster id 不连续，要按首次出现顺序重编号；说话区间会互相重叠，和 whisper 段落合并必须按重叠时长投票，用中点归属会错；小簇绝不能丢（丢了会留下大片声纹空洞，空洞里的字只能靠猜），要并入声纹最近的大簇；文字太少（< 100 字或每语音分钟 < 40 字）的录音不做分离，否则会切出幻觉说话人。
- **拖文件夹**：drop 事件一返回 `DataTransfer` 就清空了，`webkitGetAsEntry()` 必须在事件里同步取完；展开目录再异步做，`readEntries` 一次最多给 100 个，要一直读到空。
- **后台转录不能动「正在显示的结果」**：`currentTranscript` 这些全局变量是「复制纯文本」的数据源。队列在后台转的时候只更新进度页，转完用 `/api/transcript/:id` 重新加载结果；否则用户在看 A 的时候会复制到 B 的文字。
- **转录 ID 要允许中文**：只拒绝 `/`、`\`、`..`（防路径穿越）。
- **iOS Safari 拦不住刷新**：录音每秒备份到 IndexedDB，刷新后检测并恢复。
- **隔离标记**：浏览器 / AirDrop / 网盘来的文件带 `com.apple.quarantine`，内置二进制一执行就被 Gatekeeper 直接 SIGKILL（退出码 137，没有提示）。build.sh 打包前 `xattr -cr`；launcher 发现内置 node 带标记就整包清一次。
- **FFmpeg 要 arm64 原生**：常见的预编译包只有 x86_64，目标机没装 Rosetta 就跑不起来，所以从官方源码编（`--disable-autodetect`，只依赖系统库）。
- **最低系统版本**：Homebrew whisper-cpp 的 minos（当前 15.0）决定整个 .app 的最低系统版本，build.sh 自动写进 `Info.plist`，让 Finder 提示版本不够而不是莫名崩溃。
- **CoreML 版 whisper 按模型文件名找编码器**（如 `ggml-large-v3-turbo-q8_0-encoder.mlmodelc`），缺了会直接拒绝运行，不会回退。
- **证书信任不能以 root 做**：macOS 11 起改证书信任设置必须由系统弹授权框当面确认，root 进程弹不出框，输对密码也会失败 → 以当前用户身份 `security add-trusted-cert` 进登录钥匙串。
- **launcher 不能 `exec` 成常驻的 node**：LaunchServices 会把 node 登记成「正在运行的留声」，再双击只会给它发激活事件（`open` 报 -1712），launcher 根本不跑、浏览器不开。所以 node 放后台，launcher 开完浏览器就退出。
- **升级前要先结束旧 node**：端口被占时 launcher 只开浏览器，跑的仍是旧代码。
- **主程序是 shell 脚本的 .app 没有事件循环**：Dock 图标会弹跳后消失、⌘Q 不生效 → `LSUIElement=true` 不占 Dock，退出靠结束 node 进程。
- **构建机装着 Homebrew，漏打包的依赖在本机测不出来** → smoke-test 用 `sandbox-exec` 拒读 `/opt/homebrew`、`/usr/local` 再跑。
- **curl 测本机服务要加 `--noproxy '*'`**：shell 里设了 `HTTPS_PROXY` 时，请求局域网 IP 会被绕去代理然后超时。
