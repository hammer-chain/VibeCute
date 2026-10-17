#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
profile="${1:-development}"
[[ "$profile" == release || "$profile" == development ]] || { echo 'Expected release or development' >&2; exit 2; }
target_arch="${2:-$(uname -m)}"
[[ "$target_arch" == arm64 || "$target_arch" == x86_64 ]] || exit 2
suffix=""; [[ "$target_arch" == "$(uname -m)" ]] || suffix="/$target_arch"
export CAPTIONS_TARGET_ARCH="$target_arch"
export CAPTIONS_BUILD_PROFILE="$profile"
export CAPTIONS_DISTRIBUTION_BUILD=1
scratch="$PWD/.build/profiles/$profile$suffix"
dist_dir="$PWD/dist/$profile$suffix"
if [[ "$target_arch" == x86_64 ]]; then
  bash scripts/setup_intel_runtime.sh
  export CAPTIONS_BEATNET_RUNTIME="$PWD/.build/beatnet/runtime-x86_64"
  export CAPTIONS_ZSTD_LIBRARY="$PWD/.build/intel/zstd-build/lib/libzstd.dylib"
fi
export CLANG_MODULE_CACHE_PATH="$scratch/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$scratch/swift-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE" "$dist_dir"
source scripts/signing.sh
sdk=$(xcrun --show-sdk-path)
swift build --arch "$target_arch" --disable-sandbox -j 4 -c release --product CodexCaptions --scratch-path "$scratch" \
  -Xcxx -isystem -Xcxx "$sdk/usr/include/c++/v1" \
  -Xswiftc -debug-prefix-map -Xswiftc "$PWD=/app-build" \
  -Xswiftc -file-prefix-map -Xswiftc "$PWD=/app-build" \
  -Xcc "-ffile-prefix-map=$PWD=/app-build"
staging=$(mktemp -d "$dist_dir/.staging.XXXXXX")
trap 'rm -rf "$staging"' EXIT
python3 scripts/assemble_profile.py "$profile" "$scratch/$target_arch-apple-macosx/release/CodexCaptions" "$staging"
app=$(find "$staging" -maxdepth 1 -name '*.app' -type d)
install_name_tool -id @rpath/libzstd.dylib "$app/Contents/Frameworks/libzstd.dylib"
strip -S "$app/Contents/MacOS/CodexCaptions"
swift scripts/icon.swift "$app/Contents/Resources/AppIcon.icns"
python3 scripts/release_privacy.py clean "$app"
while IFS= read -r -d '' binary; do
  codesign --force "${captions_signing_arguments[@]}" "$binary"
done < <(find "$app" -type f \( -name '*.dylib' -o -name 'captions-whisper' -o -name 'captions-vocal' \) -print0)
codesign --force --deep "${captions_signing_arguments[@]}" "$app"
codesign --verify --deep --strict "$app"
python3 scripts/release_privacy.py audit "$app" --allow-host-provenance
if [[ "$profile" == release ]]; then python3 scripts/verify_release.py "$app"; fi
destination="$dist_dir/$(basename "$app")"
if [[ -d "$destination" ]]; then mv "$destination" "$staging/previous.app"; fi
if ! mv "$app" "$destination"; then
  [[ ! -d "$staging/previous.app" ]] || mv "$staging/previous.app" "$destination"
  exit 1
fi
printf 'Built: %s\n' "$destination"
