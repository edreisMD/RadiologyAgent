#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/cache .build/clang-cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
swift test --disable-sandbox --cache-path "$PWD/.build/cache"
