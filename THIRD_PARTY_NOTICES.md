# 第三方组件与许可证

留声本身以 MIT 许可证发布（见 [LICENSE](LICENSE)）。
安装包（`留声.dmg`）里还打包了下面这些第三方组件，它们各自遵循自己的许可证，版权归原作者所有。

| 组件 | 在留声里做什么 | 许可证 | 来源 |
|---|---|---|---|
| Node.js v22.18.0 | 运行服务端 | MIT（它自带的依赖见其 LICENSE） | https://nodejs.org |
| whisper.cpp（whisper-cli） | 语音识别 | MIT | https://github.com/ggml-org/whisper.cpp |
| ggml | whisper 的计算库 | MIT | https://github.com/ggml-org/ggml |
| libomp | 多线程运行库 | 见上游许可证 | https://github.com/llvm/llvm-project/tree/main/openmp |
| FFmpeg 9.0.1（ffmpeg、ffprobe） | 音频解码 | LGPL 2.1 或更高版本 | 源码：https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz ，编译参数见 `packaging/build-ffmpeg.sh`（未启用 GPL 组件） |
| mkcert v1.4.4 | 生成本机 HTTPS 证书 | BSD-3-Clause | https://github.com/FiloSottile/mkcert |
| Whisper large-v3-turbo 模型（ggml q8_0） | 语音识别模型 | MIT | https://github.com/openai/whisper ；ggml 格式：https://huggingface.co/ggerganov/whisper.cpp |
| Silero VAD v5.1.2（ggml） | 判断哪里有人说话 | MIT | https://github.com/snakers4/silero-vad ；ggml 格式：https://huggingface.co/ggml-org/whisper-vad |
| pyannote segmentation 3.0（ONNX） | 说话人分离：切分说话片段 | MIT | https://huggingface.co/pyannote/segmentation-3.0 ；ONNX 格式来自 sherpa-onnx |
| 3D-Speaker CAM++ 中文（ONNX） | 说话人分离：声纹 | Apache-2.0 | https://github.com/modelscope/3D-Speaker ；ONNX 格式来自 sherpa-onnx |
| npm 依赖（express、multer、opencc-js 等） | 服务端 | MIT / ISC / BSD-3-Clause | 见 `node_modules` 里各自的 LICENSE |

没有打包、但装了就会用上的：

| 组件 | 在留声里做什么 | 许可证 | 来源 |
|---|---|---|---|
| sherpa-onnx（装在 `~/.diar-venv`） | 运行说话人分离模型 | Apache-2.0 | https://github.com/k2-fsa/sherpa-onnx |

如果你发现这里有遗漏或写错的地方，欢迎提 issue。
