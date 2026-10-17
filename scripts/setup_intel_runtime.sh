#!/bin/bash
# Pinned, isolated x86_64 dependencies; never overwrite the ARM runtime.
set -euo pipefail
cd "$(dirname "$0")/.."
cmake="$PWD/.build/beatnet/tools/cmake/data/bin/cmake"
[[ -x "$cmake" ]] || python3 -m pip install --target .build/beatnet/tools cmake==4.4.4
revision=3612c0af93f2cfc8f048295300a61187723b12ae
if [[ ! -d .build/beatnet/ggml/.git ]]; then
 git clone https://github.com/ggml-org/ggml .build/beatnet/ggml
 git -C .build/beatnet/ggml checkout --detach "$revision"
fi
[[ "$(git -C .build/beatnet/ggml rev-parse HEAD)" == "$revision" ]]
mkdir -p .build/intel .build/beatnet/runtime-x86_64
if [[ ! -d .build/intel/zstd-1.5.7 ]]; then
 curl -fL --retry 2 https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz -o .build/intel/zstd.tar.gz
 python3 - <<'CHECK'
import hashlib
from pathlib import Path
assert hashlib.sha256(Path('.build/intel/zstd.tar.gz').read_bytes()).hexdigest() == 'eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3', 'Zstd source checksum mismatch'
CHECK
 tar -xzf .build/intel/zstd.tar.gz -C .build/intel
fi
sdk=$(xcrun --show-sdk-path)
"$cmake" -S .build/intel/zstd-1.5.7/build/cmake -B .build/intel/zstd-build \
 -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
 -DZSTD_BUILD_PROGRAMS=OFF -DZSTD_BUILD_TESTS=OFF -DZSTD_BUILD_STATIC=OFF -DZSTD_BUILD_SHARED=ON \
 -DCMAKE_C_FLAGS="-ffile-prefix-map=$PWD=/app-build -ffile-prefix-map=$sdk=/sdk"
"$cmake" --build .build/intel/zstd-build -j 4
"$cmake" -S Sources/BeatNetBridge/runtime -B .build/beatnet/build-x86_64 \
 -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
 -DGGML_SOURCE="$PWD/.build/beatnet/ggml" -DGGML_NATIVE=OFF \
 -DGGML_AVX=OFF -DGGML_AVX2=OFF -DGGML_AVX512=OFF -DGGML_FMA=OFF -DGGML_F16C=OFF \
 -DCMAKE_CXX_FLAGS="-isystem $sdk/usr/include/c++/v1 -ffile-prefix-map=$PWD=/app-build" \
 -DCMAKE_C_FLAGS="-ffile-prefix-map=$PWD=/app-build"
"$cmake" --build .build/beatnet/build-x86_64 --target caption_beatnet beatnet-parity -j 4
runtime=.build/beatnet/runtime-x86_64
cp .build/beatnet/build-x86_64/libcaption_beatnet.dylib "$runtime/"
cp Sources/BeatNetBridge/vendor/models/generic-f32.gguf "$runtime/"
cp Sources/BeatNetBridge/COPYING "$runtime/BeatNetPlus-LICENSE.txt"
cp .build/beatnet/ggml/LICENSE "$runtime/ggml-LICENSE.txt"
cp Sources/BeatNetBridge/vendor/third_party/pocketfft_hdronly.h "$runtime/PocketFFT-NOTICE.txt"
printf '%s\n' 'BeatNet+ weights: non-commercial use only; https://github.com/key2/beatnetplus.cpp#dependencies-and-licenses' > "$runtime/Weights-NOTICE.txt"
