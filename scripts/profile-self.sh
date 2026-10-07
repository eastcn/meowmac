#!/usr/bin/env bash
# 显式性能测量。默认自测仍保持后台。
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 scripts/self-performance.py "$@"
