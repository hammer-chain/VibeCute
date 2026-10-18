#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CAPTIONS_BUILD_PROFILE=development
unset CAPTIONS_DISTRIBUTION_BUILD
scratch="$PWD/.build/developer-preview"
mkdir -p output/desktop-rain /tmp/hoodie-empty-sessions
sdk=$(xcrun --show-sdk-path)
swift build --disable-sandbox --scratch-path "$scratch" -j 4 --product CodexCaptions -Xcxx -isystem -Xcxx "$sdk/usr/include/c++/v1"
mkdir -p output/desktop-rain/geometry
cp Tests/RainGeometryChecks.swift output/desktop-rain/geometry/main.swift
swiftc -module-cache-path .build/clang-cache Sources/CodexCaptions/RainGeometry.swift output/desktop-rain/geometry/main.swift -o .build/rain-geometry-checks
.build/rain-geometry-checks
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
    Tests/DesktopRainChecks.swift "${objects[@]}" -framework Accelerate -lc++ -lsqlite3 -o .build/desktop-rain-checks
.build/desktop-rain-checks --preferences-suite local.vibecute.desktop-rain-checks --no-audio --no-speech --no-vocal-separation --no-task-sounds --no-question-sounds --no-doubao --no-workbuddy --no-position-memory --sessions-root /tmp/hoodie-empty-sessions --deepseek-root /tmp/hoodie-empty-sessions --claude-root /tmp/hoodie-empty-sessions --opencode-root /tmp/hoodie-empty-sessions --workbuddy-root /tmp/hoodie-empty-sessions
