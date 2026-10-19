#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> 编译 VirtualBassLab..."
swift build -c debug

BINARY="$SCRIPT_DIR/.build/out/Products/Debug/VirtualBassLab"

echo "==> 启动 VirtualBassLab (PID: $$)..."
"$BINARY"
