#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/hybrid-hoodie .build/clang-cache output/hybrid-hoodie
swiftc -O -module-cache-path .build/clang-cache Sources/CodexCaptions/HybridHoodieArtwork.swift \
  Tests/HybridHoodieChecks.swift -o .build/hybrid-hoodie/check
.build/hybrid-hoodie/check
