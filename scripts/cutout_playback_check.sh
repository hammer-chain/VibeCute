#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/cutout .build/clang-cache
cat > .build/cutout/playback_accessor.swift <<'SWIFT'
import Foundation
extension Bundle { static let module = Bundle.main }
SWIFT
swiftc -O -module-cache-path .build/clang-cache Sources/CodexCaptions/CutoutRig.swift \
  Sources/CodexCaptions/CutoutArtwork.swift Sources/CodexCaptions/CutoutCharacter.swift Sources/CodexCaptions/CutoutPixels.swift \
  .build/cutout/playback_accessor.swift Tests/CutoutPlaybackChecks.swift -o .build/cutout/playback-check
.build/cutout/playback-check
