#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
sdk_path=$(xcrun --show-sdk-path)
swift build --disable-sandbox -j 4 --product CodexCaptions -Xcxx -isystem -Xcxx "$sdk_path/usr/include/c++/v1"
bin=$(swift build --show-bin-path)
swiftc -module-cache-path .build/clang-cache Sources/CodexCaptions/MascotAnimation.swift \
    Sources/CodexCaptions/CutoutCharacter.swift Sources/CodexCaptions/CutoutRig.swift \
    Sources/CodexCaptions/ThinkingGazeRegistration.swift \
    "$bin/CodexCaptions.build/DerivedSources/resource_bundle_accessor.swift" \
    Tests/OrangeHoodieChecks.swift -o .build/orange-hoodie-checks
.build/orange-hoodie-checks "${1:-/tmp/orange-hoodie-render.png}"
