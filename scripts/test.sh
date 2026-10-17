#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Some Command Line Tools installs expose libc++ headers only inside the SDK.
captions_sdk_path=$(xcrun --show-sdk-path)
captions_cxx_arguments=(-Xcxx -isystem -Xcxx "$captions_sdk_path/usr/include/c++/v1")
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
mkdir -p output/deepseek-singing
swift run --disable-sandbox "${captions_cxx_arguments[@]}" -j 4 --scratch-path .build CaptionCoreChecks
