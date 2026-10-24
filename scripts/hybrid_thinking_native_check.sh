#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
sdk_path=$(xcrun --show-sdk-path)
swift build --disable-sandbox -j 4 --product CodexCaptions -Xcxx -isystem -Xcxx "$sdk_path/usr/include/c++/v1"
bin=$(swift build --show-bin-path)
objects=()
while IFS= read -r file; do
    [[ "$file" == */CodexCaptions.build/main.swift.o ]] || objects+=("$file")
done < "$bin/CodexCaptions.product/Objects.LinkFileList"
swiftc -module-cache-path .build/clang-cache -parse-as-library -I "$bin/Modules" -I Sources/CSQLite -I Sources/ZstdBridge/include \
    -I Sources/AubioBridge/include \
    -Xcc "-fmodule-map-file=$bin/ZstdBridge.build/module.modulemap" \
    -Xcc "-fmodule-map-file=$bin/AubioBridge.build/module.modulemap" \
    -Xcc "-fmodule-map-file=$bin/BTrackBridge.build/module.modulemap" \
    -Xcc "-fmodule-map-file=$bin/BeatNetBridge.build/module.modulemap" \
    Tests/HybridThinkingNativeChecks.swift "${objects[@]}" -framework Accelerate -lc++ -lsqlite3 -o .build/hybrid-thinking-native-checks
.build/hybrid-thinking-native-checks
