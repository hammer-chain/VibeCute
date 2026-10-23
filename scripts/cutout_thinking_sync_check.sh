#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/cutout .build/clang-cache
cat > .build/cutout/thinking_accessor.swift <<'SWIFT'
import Foundation
extension Bundle { static let module = Bundle.main }
SWIFT
swiftc -O -module-cache-path .build/clang-cache Sources/CodexCaptions/CutoutRig.swift \
 Sources/CodexCaptions/CutoutArtwork.swift Sources/CodexCaptions/CutoutCharacter.swift Sources/CodexCaptions/CutoutPixels.swift \
 .build/cutout/thinking_accessor.swift Tests/CutoutThinkingSyncChecks.swift -o .build/cutout/thinking-sync-check
.build/cutout/thinking-sync-check
