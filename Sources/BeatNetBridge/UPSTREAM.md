# BeatNet+ C++ experiment

Source: https://github.com/key2/beatnetplus.cpp
Commit: 624eb3b3b9a3e984a35478a283f82ac92cbe37ff
Code: MIT (COPYING). PocketFFT: BSD-3-Clause (header notice).
Weights: generic-f32.gguf, non-commercial use only (upstream authors' terms).
GGML: MIT, revision 3612c0af93f2cfc8f048295300a61187723b12ae.

Run bash scripts/setup_beatnet.sh to build the local C++ runtime. Dependencies
are prepared under .build/beatnet; no global Python packages or runtime Python.
The pinned 3.4 MB weights are vendored. Verify their checksum with shasum -a 256.

The SwiftPM C bridge dynamically loads the packaged dylib via a checked explicit
path. Streaming feature extraction, scalar CRNN and causal particle filter run
on one utility worker in 100 ms batches. At most three batches are queued;
overload invalidates the phase and resets the stream rather than retaining old
PCM or reporting stale beats. Model initialization is lazy and worker-only.
Music veto and independent recent-onset gating are retained. Confidence is
interval consistency, not a calibrated network probability. No octave correction.

The C++ adapter uses upstream features/model/filter without algorithm edits.
Only the most recent filter event is retained: the upstream filter accesses only
path.back(). This removes unbounded event history. 60-second parity/reset check
compares every event with the upstream beatnet_stream before packaging.
Feature buffers are upstream sliding windows. Swift keeps only eight beat times.
Default particle tempo space is 55–215 BPM; 240 BPM is outside that space.

Development runtime: .build/beatnet/runtime. Packaged runtime:
Contents/Resources/BeatNet. Override: CAPTIONS_BEATNET_RUNTIME.
If missing/invalid, this engine produces no estimate and logs a load failure;
it never labels an aubio fallback as BeatNet+. Toggle engine after installing.
This experiment is for local non-commercial evaluation, not a commercial release.
