#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
profile="${CAPTIONS_BUILD_PROFILE:-development}"
scratch="$PWD/.build/settings-checks/$profile"
# This is a resource-backed native test build, independent of packaged artifacts.
unset CAPTIONS_DISTRIBUTION_BUILD
export CLANG_MODULE_CACHE_PATH="$scratch/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$scratch/swift-cache"
mkdir -p output/native-settings/empty-sessions
sdk=$(xcrun --show-sdk-path)
swift build --disable-sandbox --scratch-path "$scratch" -j 4 --product CodexCaptions -Xcxx -isystem -Xcxx "$sdk/usr/include/c++/v1" > output/native-settings/check-build.log 2>&1
bin=$(swift build --disable-sandbox --scratch-path "$scratch" --show-bin-path)
# Compile the actual lifecycle implementation without its production entrypoint;
# access modifiers alone are relaxed so the native integration check can call it.
python3 - <<'PY'
from pathlib import Path
source=Path('Sources/CodexCaptions/main.swift').read_text().split('let application = NSApplication.shared')[0]
source=source.replace('import SwiftUI', 'import SwiftUI\n@testable import CodexCaptions').replace('private ', '')
Path('output/native-settings/AcceptanceDelegate.swift').write_text(source)
PY
objects=()
while IFS= read -r file; do
    [[ "$file" == */main.swift.o ]] || objects+=("$file")
done < "$bin/CodexCaptions.product/Objects.LinkFileList"
profile_flags=(-D VIBECUTE_DEVELOPMENT)
[[ "$profile" != release ]] || profile_flags=(-D VIBECUTE_RELEASE)
module_maps=()
for bridge in ZstdBridge AubioBridge BTrackBridge BeatNetBridge; do
    map="$bin/$bridge.build/module.modulemap"
    [[ ! -f "$map" ]] || module_maps+=(-Xcc "-fmodule-map-file=$map")
done
swiftc -module-cache-path "$CLANG_MODULE_CACHE_PATH" -I "$bin/Modules" -I Sources/CSQLite \
  "${module_maps[@]}" "${profile_flags[@]}" \
  output/native-settings/AcceptanceDelegate.swift Tests/SettingsUI/main.swift "${objects[@]}" \
  -framework Accelerate -lc++ -o .build/SettingsUIAcceptance
suite="app.vibecute.settings-check.$$"
trap 'defaults delete "$suite" >/dev/null 2>&1 || true' EXIT
.build/SettingsUIAcceptance --preferences-suite "$suite" --sessions-root "$PWD/output/native-settings/empty-sessions" --no-position-memory --no-approval-stream --no-audio --no-speech --no-avoidance
