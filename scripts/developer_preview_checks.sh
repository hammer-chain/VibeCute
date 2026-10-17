#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bin=$(swift build --show-bin-path)
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
    Tests/DeveloperPreviewChecks.swift "${objects[@]}" -framework Accelerate -lc++ -o .build/developer-preview-checks
.build/developer-preview-checks --preferences-suite local.vibecute.developer-preview-checks --no-audio --no-speech --no-vocal-separation --no-task-sounds --no-question-sounds --no-doubao --no-workbuddy --no-position-memory --sessions-root /tmp/hoodie-empty-sessions --deepseek-root /tmp/hoodie-empty-sessions --claude-root /tmp/hoodie-empty-sessions --opencode-root /tmp/hoodie-empty-sessions --workbuddy-root /tmp/hoodie-empty-sessions
