#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi
mkdir -p .build/cache .build/module-cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFT_MODULECACHE_PATH="$PWD/.build/module-cache"
swift test --disable-sandbox --cache-path "$PWD/.build/cache" -Xswiftc -module-cache-path -Xswiftc "$PWD/.build/module-cache"
