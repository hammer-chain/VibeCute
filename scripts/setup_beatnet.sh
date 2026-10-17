#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Local experiment only: weights are licensed for non-commercial use.
ggml_revision=3612c0af93f2cfc8f048295300a61187723b12ae
mkdir -p .build/beatnet/runtime
if [[ ! -f .build/beatnet/tools/cmake/data/bin/cmake ]]; then
 python3 -m pip install --target .build/beatnet/tools cmake==4.4.4
fi
if [[ ! -d .build/beatnet/ggml/.git ]]; then
 git clone https://github.com/ggml-org/ggml .build/beatnet/ggml
fi
if [[ "$(git -C .build/beatnet/ggml rev-parse HEAD)" != "$ggml_revision" ]]; then
 git -C .build/beatnet/ggml fetch origin "$ggml_revision"
 git -C .build/beatnet/ggml checkout --detach "$ggml_revision"
fi
sdk=$(xcrun --show-sdk-path)
cmake=.build/beatnet/tools/cmake/data/bin/cmake
"$cmake" -S Sources/BeatNetBridge/runtime -B .build/beatnet/build -DCMAKE_BUILD_TYPE=Release \
 -DGGML_SOURCE="$PWD/.build/beatnet/ggml" -DCMAKE_CXX_FLAGS="-isystem $sdk/usr/include/c++/v1 -ffile-prefix-map=$PWD=/app-build" \
 -DCMAKE_C_FLAGS="-ffile-prefix-map=$PWD=/app-build" -DGGML_NATIVE=OFF
"$cmake" --build .build/beatnet/build --target caption_beatnet beatnet-parity -j 4
cp .build/beatnet/build/libcaption_beatnet.dylib .build/beatnet/runtime/
cp Sources/BeatNetBridge/vendor/models/generic-f32.gguf .build/beatnet/runtime/
cp Sources/BeatNetBridge/COPYING .build/beatnet/runtime/BeatNetPlus-LICENSE.txt
cp .build/beatnet/ggml/LICENSE .build/beatnet/runtime/ggml-LICENSE.txt
cp Sources/BeatNetBridge/vendor/third_party/pocketfft_hdronly.h .build/beatnet/runtime/PocketFFT-NOTICE.txt
printf '%s\n' 'BeatNet+ weights: non-commercial use only; https://github.com/key2/beatnetplus.cpp#dependencies-and-licenses' > .build/beatnet/runtime/Weights-NOTICE.txt
