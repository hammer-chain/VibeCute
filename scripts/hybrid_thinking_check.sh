#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/hybrid-hoodie output/hybrid-hoodie/thinking
swiftc -O -module-cache-path .build/clang-cache Sources/CodexCaptions/HybridHoodieArtwork.swift \
  Sources/CodexCaptions/HybridHoodieThinking.swift Tests/HybridThinkingChecks.swift -o .build/hybrid-hoodie/thinking-check
.build/hybrid-hoodie/thinking-check
