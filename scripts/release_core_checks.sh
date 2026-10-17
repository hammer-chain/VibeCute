#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
target_arch="${1:-$(uname -m)}"
suffix=""; [[ "$target_arch" == "$(uname -m)" ]] || suffix="/$target_arch"
scratch="$PWD/.build/profiles/release$suffix"
report_dir="$PWD/output/release$suffix"
bin=$(CAPTIONS_BUILD_PROFILE=release CAPTIONS_DISTRIBUTION_BUILD=1 swift build --arch "$target_arch" --disable-sandbox -c release --scratch-path "$scratch" --show-bin-path)
qa="$report_dir/core-check.app"
mkdir -p "$qa/Contents/MacOS"
python3 - "$qa" "$PWD/dist/release$suffix/VibeCute.app/Contents/Resources" <<'PY'
import plistlib,sys
from pathlib import Path
p=Path(sys.argv[1])
(p/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'app.vibecute.release-core-check','CFBundleExecutable':'CoreChecks','CFBundlePackageType':'APPL'}))
resources=p/'Contents/Resources'
if resources.is_symlink(): resources.unlink()
resources.symlink_to(Path(sys.argv[2]).resolve())
PY
objects=()
for target in CaptionCore ZstdBridge BeatNetBridge; do
  while IFS= read -r file; do objects+=("$file"); done < <(find "$bin/$target.build" -name '*.o' -type f)
done
swiftc -target "$target_arch-apple-macosx13.0" -O -module-cache-path "$scratch/clang-cache" -I "$bin/Modules" -I Sources/CSQLite \
  -Xcc "-fmodule-map-file=$bin/ZstdBridge.build/module.modulemap" \
  -Xcc "-fmodule-map-file=$bin/BeatNetBridge.build/module.modulemap" \
  Tests/ReleaseCore/main.swift "${objects[@]}" -framework Accelerate -lsqlite3 -o "$qa/Contents/MacOS/CoreChecks"
"$qa/Contents/MacOS/CoreChecks"
missing="$report_dir/missing-runtime-check.app"
mkdir -p "$missing/Contents/MacOS" "$missing/Contents/Resources"
cp "$qa/Contents/Info.plist" "$missing/Contents/Info.plist"
cp "$qa/Contents/MacOS/CoreChecks" "$missing/Contents/MacOS/CoreChecks"
"$missing/Contents/MacOS/CoreChecks" --missing-runtime
