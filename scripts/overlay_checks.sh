#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
sdk=$(xcrun --show-sdk-path)
swift build --disable-sandbox --product CodexCaptions --scratch-path .build -j 4 \
    -Xcxx -isystem -Xcxx "$sdk/usr/include/c++/v1" > /dev/null
bin=$(swift build --show-bin-path --scratch-path .build)
mkdir -p .build/performance
sources=()
source_directory="${OVERLAY_SOURCE_DIRECTORY:-Sources/CodexCaptions}"
for file in "$source_directory"/*.swift; do
    [[ "${file##*/}" == main.swift ]] || sources+=("$file")
done
objects=()
while IFS= read -r file; do
    [[ "$file" == */CodexCaptions.build/* ]] || objects+=("$file")
done < "$bin/CodexCaptions.product/Objects.LinkFileList"
name="OverlayPerformanceChecks"
output="${OVERLAY_CHECKS_OUTPUT:-.build/performance/OverlayPerformanceChecks}"
flags=("${OVERLAY_CHECKS_OPTIMIZATION:--O}")
[[ "${PERFORMANCE_COUNTERS:-1}" == 0 ]] || flags+=(-D PERFORMANCE_COUNTERS)
swiftc -module-cache-path .build/clang-cache -I "$bin/Modules" \
    -I Sources/CSQLite -I Sources/ZstdBridge/include -I Sources/AubioBridge/include \
    -Xcc "-fmodule-map-file=$bin/ZstdBridge.build/module.modulemap" \
    -Xcc "-fmodule-map-file=$bin/AubioBridge.build/module.modulemap" \
    -Xcc "-fmodule-map-file=$bin/BTrackBridge.build/module.modulemap" \
    -Xcc "-fmodule-map-file=$bin/BeatNetBridge.build/module.modulemap" \
    "${flags[@]}" "${sources[@]}" "$bin/CodexCaptions.build/DerivedSources/resource_bundle_accessor.swift" \
    "Tests/$name.swift" "${objects[@]}" -framework Accelerate -lc++ -o "$output"
[[ "${OVERLAY_CHECKS_BUILD_ONLY:-0}" == 1 ]] || "$output"
