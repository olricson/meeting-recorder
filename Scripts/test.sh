#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi
export CLANG_MODULE_CACHE_PATH="$repo_dir/.build/test-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$repo_dir/.build/test-swiftpm-cache"
cd "$repo_dir"
/usr/bin/swift test --disable-sandbox
