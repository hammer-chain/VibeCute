#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/cutout .build/clang-cache
cat > .build/cutout/wardrobe_accessor.swift <<'SWIFT'
import Foundation
extension Bundle {static let module=Bundle.main}
SWIFT
swiftc -O -module-cache-path .build/clang-cache Sources/CodexCaptions/CutoutRig.swift \
  Sources/CodexCaptions/CutoutArtwork.swift Sources/CodexCaptions/CutoutCharacter.swift Sources/CodexCaptions/CutoutPixels.swift \
  .build/cutout/wardrobe_accessor.swift Tests/CutoutWardrobeChecks.swift -o .build/cutout/wardrobe-check
.build/cutout/wardrobe-check
