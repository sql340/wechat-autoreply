#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release

mkdir -p bin
cp .build/release/wechat-autoreply bin/wechat-autoreply
cp .build/release/self-test bin/self-test

echo "已构建："
echo "  $ROOT/bin/wechat-autoreply"
echo "  $ROOT/bin/self-test"
echo
echo "如果移动了二进制路径，需要在“系统设置 → 隐私与安全性 → 辅助功能”中重新授权。"
