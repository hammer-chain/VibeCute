#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CAPTIONS_BUILD_PROFILE=development
unset CAPTIONS_DISTRIBUTION_BUILD
scratch="$PWD/.build/idle-work-resume"
sdk=$(xcrun --show-sdk-path)
swift build --disable-sandbox --scratch-path "$scratch" -j 4 --product CodexCaptions -Xcxx -isystem -Xcxx "$sdk/usr/include/c++/v1"
bin=$(swift build --disable-sandbox --scratch-path "$scratch" --show-bin-path)
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
    Tests/DSHQuestionNativeChecks.swift "${objects[@]}" -framework Accelerate -lc++ -lsqlite3 -o .build/dsh-question-native-checks
.build/dsh-question-native-checks --log "$1"
