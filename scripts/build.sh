#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
profile="${1:-development}"
case "$profile" in
    full|development) exec bash scripts/build_profile.sh development ;;
    release) exec bash scripts/build_profile.sh release ;;
esac
if [[ "$profile" != full && "$profile" != minimal ]]; then echo "Usage: $0 [development|release|full|minimal]" >&2; exit 2; fi
source scripts/signing.sh
bash scripts/cutout_runtime_check.sh
# Some Command Line Tools installs expose libc++ headers only inside the SDK.
captions_sdk_path=$(xcrun --show-sdk-path)
captions_cxx_arguments=(-Xcxx -isystem -Xcxx "$captions_sdk_path/usr/include/c++/v1")
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"
CAPTIONS_DISTRIBUTION_BUILD=1 swift build --disable-sandbox "${captions_cxx_arguments[@]}" -j 4 -c release --product CodexCaptions --scratch-path .build \
    -Xswiftc -debug-prefix-map -Xswiftc "$PWD=/app-build" \
    -Xswiftc -file-prefix-map -Xswiftc "$PWD=/app-build" \
    -Xcc "-ffile-prefix-map=$PWD=/app-build"
captions_app_destination="$PWD/dist/VibeCute.app"
mkdir -p "$PWD/dist"
captions_build_staging=$(mktemp -d "$PWD/dist/.captions-build.XXXXXX")
trap 'rm -rf "$captions_build_staging"' EXIT
app="$captions_build_staging/VibeCute.app"
# Always assemble a clean bundle so optional components cannot leak from old builds.
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
zstd_lib="${CAPTIONS_ZSTD_LIBRARY:-/opt/homebrew/opt/zstd/lib/libzstd.dylib}"
if [[ ! -f "$zstd_lib" ]]; then zstd_lib=/usr/local/opt/zstd/lib/libzstd.dylib; fi
if [[ ! -f "$zstd_lib" ]]; then
    echo 'libzstd not found. Set CAPTIONS_ZSTD_LIBRARY to libzstd.dylib.' >&2
    exit 1
fi
mkdir -p "$app/Contents/Frameworks"
if [[ -f "$app/Contents/Frameworks/libzstd.dylib" ]]; then chmod u+w "$app/Contents/Frameworks/libzstd.dylib"; fi
cp -L "$zstd_lib" "$app/Contents/Frameworks/libzstd.dylib"
chmod u+w "$app/Contents/Frameworks/libzstd.dylib"
codesign --force "${captions_signing_arguments[@]}" "$app/Contents/Frameworks/libzstd.dylib"
cp .build/release/CodexCaptions "$app/Contents/MacOS/"
strip -S "$app/Contents/MacOS/CodexCaptions"
cp Resources/Info.plist "$app/Contents/Info.plist"
if [[ "$profile" == minimal ]]; then
    # Bundled Homebrew zstd currently targets macOS 15.
    /usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 15.0" "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CaptionsMinimalRelease bool true" "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${CAPTIONS_BUILD_NUMBER:-2026101303}" "$app/Contents/Info.plist"
fi
cp Resources/Zstandard-LICENSE.txt Resources/Aubio-LICENSE.txt "$app/Contents/Resources/"
cp Sources/BTrackBridge/COPYING "$app/Contents/Resources/BTrack-LICENSE.txt"
cp Sources/BTrackBridge/vendor/COPYING "$app/Contents/Resources/KissFFT-LICENSE.txt"
cp Sources/SamplerateBridge/COPYING "$app/Contents/Resources/Libsamplerate-LICENSE.txt"
if [[ -f .build/beatnet/runtime/libcaption_beatnet.dylib ]]; then
    cp -R .build/beatnet/runtime "$app/Contents/Resources/BeatNet"
    codesign --force "${captions_signing_arguments[@]}" "$app/Contents/Resources/BeatNet/libcaption_beatnet.dylib"
fi
if [[ "$profile" == full && -x .build/whisper/runtime/captions-whisper && -f .build/whisper/runtime/ggml-small-q5_1.bin ]]; then
    mkdir -p "$app/Contents/Resources/Whisper"
    cp .build/whisper/runtime/* "$app/Contents/Resources/Whisper/"
    codesign --force "${captions_signing_arguments[@]}" "$app/Contents/Resources/Whisper/captions-whisper"
fi
if [[ "$profile" == full && -x .build/vocal-separation/runtime/captions-vocal && -f .build/vocal-separation/runtime/model.onnx ]]; then
    mkdir -p "$app/Contents/Resources/Vocal"
    cp .build/vocal-separation/runtime/captions-vocal .build/vocal-separation/runtime/model.onnx \
        .build/vocal-separation/runtime/libonnxruntime.1.dylib \
        .build/vocal-separation/runtime/*-LICENSE.txt "$app/Contents/Resources/Vocal/"
    codesign --force "${captions_signing_arguments[@]}" "$app/Contents/Resources/Vocal/libonnxruntime.1.dylib"
    codesign --force "${captions_signing_arguments[@]}" "$app/Contents/Resources/Vocal/captions-vocal"
fi
# Replace declared SwiftPM resource directories in staging, dropping stale frames.
# Remove the retired contract resource from bundles built by earlier versions.
rm -rf "$app/Contents/Resources/CharacterDefinitions"
for directory in CutoutCharacters DeepSeekCutout DeepSeekThinking OrangeHoodieThinking CodexThinking OpenCodeNavigation; do
    rm -rf "$app/Contents/Resources/$directory"
    cp -R "Sources/CodexCaptions/Resources/$directory" "$app/Contents/Resources/"
done
cp Sources/CodexCaptions/Resources/LipVowels.json "$app/Contents/Resources/"
swift scripts/icon.swift "$app/Contents/Resources/AppIcon.icns"
# Clean only the assembled bundle, preserving source assets and developer metadata.
python3 scripts/release_privacy.py clean "$app"
codesign --force --deep "${captions_signing_arguments[@]}" "$app"
python3 scripts/release_privacy.py clean "$app"
codesign --verify --deep --strict "$app"
python3 scripts/release_privacy.py audit "$app" --allow-host-provenance
if [[ -d "$captions_app_destination" ]]; then mv "$captions_app_destination" "$captions_build_staging/previous.app"; fi
if ! mv "$app" "$captions_app_destination"; then
    if [[ -d "$captions_build_staging/previous.app" ]]; then mv "$captions_build_staging/previous.app" "$captions_app_destination"; fi
    exit 1
fi
printf 'Built: %s\n' "$captions_app_destination"
