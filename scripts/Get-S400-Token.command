#!/bin/zsh
set -eu
umask 077
cd "$(dirname "$0")/.."
if [[ ! -x .build/token-tools-env/bin/python ]]; then
  print '尚未准备提取工具环境，请先按 docs/TOKEN_SETUP.md 安装依赖。'
  read '?按回车退出'
  exit 1
fi
if [[ -f .build/token-target-mac ]]; then
  export S400_TARGET_MAC="$(cat .build/token-target-mac)"
else
  read 'S400_TARGET_MAC?请输入 App 设备详情中的 S400 MAC：'
  export S400_TARGET_MAC
fi
print '只提取你选择的体脂秤。建议选择 q 扫码登录，二维码地址仅在本机开放。'
print '完成后把 TOKEN 填入 iPhone App，不要发送到聊天或分享终端截图。'
print '没有 24 位 TOKEN 时请停止。不要截断其他字段或分享任何密钥。'
.build/token-tools-env/bin/python Tools/TokenExtractor/token_extractor.py --log_level CRITICAL --host 127.0.0.1
