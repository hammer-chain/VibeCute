#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p output/desktop-rain .build/clang-cache
swiftc -O -module-cache-path .build/clang-cache -parse-as-library \
  Sources/CodexCaptions/RainGeometry.swift Sources/CodexCaptions/RainView.swift \
  Tests/RainPerformanceChecks.swift -o .build/rain-performance-checks
.build/rain-performance-checks
