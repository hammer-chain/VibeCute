#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/cutout .build/clang-cache
cat > .build/cutout/seam_accessor.swift <<'SWIFT'
import Foundation
extension Bundle { static let module = Bundle.main }
SWIFT
swiftc -O -module-cache-path .build/clang-cache Sources/CodexCaptions/CutoutRig.swift \
 Sources/CodexCaptions/CutoutArtwork.swift Sources/CodexCaptions/CutoutCharacter.swift Sources/CodexCaptions/CutoutPixels.swift \
 .build/cutout/seam_accessor.swift Tests/CutoutHairSeamChecks.swift -o .build/cutout/hair-seam-check
.build/cutout/hair-seam-check
