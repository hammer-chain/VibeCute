# BTrack 1.0.7

Source: https://github.com/adamstark/BTrack
Commit: 9d6127618a5679e9caa74c594b88f1d74f0e035f
License: GPL-3.0-or-later (COPYING); Kiss FFT has its own BSD notice in vendor/COPYING.

Fixed 512-sample hops, 1024-sample windows, 44100 Hz. Swift linearly interpolates
16 kHz analyzer PCM to this clock; no file analysis, Python or model weights.
Local upstream changes: initialize SRC_DATA including end_of_input; copy the
512-element onset grid directly at a 1:1 ratio, avoiding per-beat sinc setup.
Other hop sizes retain upstream libsamplerate resampling.

libsamplerate source: https://github.com/libsndfile/libsamplerate
Commit: 0844c208f683527c08ea8a80acc13b398aa9c8bf
Vendored in SamplerateBridge, BSD-2-Clause; version string supplied locally.

BTrack produces predicted beats even without music, and no confidence probability.
The adapter gates output on music context, recent independently observed attacks,
and four stable beat estimates. It exposes raw BTrack BPM without octave correction.
