#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p output/review-followups
scratch="$PWD/.build/settings-checks/release"
export CAPTIONS_BUILD_PROFILE=release
unset CAPTIONS_DISTRIBUTION_BUILD
export CLANG_MODULE_CACHE_PATH="$scratch/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$scratch/swift-cache"
sdk=$(xcrun --show-sdk-path)
swift build --disable-sandbox --scratch-path "$scratch" -j 4 --product CodexCaptions -Xcxx -isystem -Xcxx "$sdk/usr/include/c++/v1"
bin=$(swift build --disable-sandbox --scratch-path "$scratch" --show-bin-path)
objects=()
while IFS= read -r file; do
 [[ "$file" == */main.swift.o ]] || objects+=("$file")
done < "$bin/CodexCaptions.product/Objects.LinkFileList"
module_maps=()
for bridge in ZstdBridge BeatNetBridge; do
 module_maps+=(-Xcc "-fmodule-map-file=$bin/$bridge.build/module.modulemap")
done
checks=(ReviewLifecycleChecks CodexReplySnapshotChecks)
if [[ "$#" -gt 0 ]]; then checks=("$@"); fi
for check in "${checks[@]}"; do
 case "$check" in ReviewLifecycleChecks|CodexReplySnapshotChecks) ;; *) exit 2 ;; esac
 swiftc -parse-as-library -D VIBECUTE_RELEASE -module-cache-path "$CLANG_MODULE_CACHE_PATH" -I "$bin/Modules" -I Sources/CSQLite \
  "${module_maps[@]}" "Tests/$check.swift" "${objects[@]}" -framework Accelerate -lc++ -lsqlite3 -o "output/review-followups/$check"
 "output/review-followups/$check"
done
