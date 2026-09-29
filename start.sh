#!/usr/bin/env bash
# 留声 开发启动脚本 —— 启用 CoreML（Apple 神经引擎）加速的 whisper
#
# CoreML 版 whisper-cli 由 ~/.whisper-build/whisper.cpp 自编译（带 -DWHISPER_COREML=1）；
# 编码器模型 ggml-large-v3-turbo-encoder.mlmodelc 已放在 ~/.whisper-models/，whisper 自动启用。
# 实测整体比 brew 版（Metal）快 ~2.4x。
#
# 用法: ./start.sh      （想用回 brew 版就直接 node server.js）
set -euo pipefail
cd "$(dirname "$0")"

COREML_CLI="$HOME/.whisper-build/whisper.cpp/build/bin/whisper-cli"
if [[ -x "$COREML_CLI" ]]; then
  export WHISPER_CLI="$COREML_CLI"
  echo "[start] 使用 CoreML 加速的 whisper-cli: $WHISPER_CLI"
else
  echo "[start] 未找到 CoreML 版（$COREML_CLI），回退 brew 版 whisper-cli"
fi

# 本机装过安装版（留声.app）的话，复用它那套证书：CA 已被这台 Mac 信任，SAN 含本机 .local 名和局域网 IP，
# 浏览器不报警告；没装过安装版就用项目里的 certs/（需要自己用 mkcert 生成，见 docs）。
# 本机 IP 变了：双击一次「应用程序」里的留声，它会重签，这边几秒内热加载
APP_CERTS="$HOME/Library/Application Support/留声/certs"
if [[ -r "$APP_CERTS/cert.pem" && -r "$APP_CERTS/key.pem" && -r "$APP_CERTS/CAROOT/rootCA.pem" ]]; then
  export CERTS_DIR="$APP_CERTS" ROOT_CA_PEM="$APP_CERTS/CAROOT/rootCA.pem"
  echo "[start] 使用安装版的本机已信任证书: $CERTS_DIR"
else
  echo "[start] 未找到安装版证书（$APP_CERTS），回退项目自带 certs/"
fi

exec node server.js
