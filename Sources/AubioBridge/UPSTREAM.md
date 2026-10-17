# aubio 0.4.9

Source: https://aubio.org/pub/aubio-0.4.9.tar.bz2
License: GPL-3.0-or-later; see COPYING and the original file headers.

Only the C tempo detector and its supporting vector, FFT, spectral descriptor,
peak-picking and filtering code are compiled. Upstream source files are unchanged.
The custom bridge and macOS configuration are outside vendor/. Apple Accelerate
is used for FFT; file readers, codecs, Python and external audio libraries are absent.

Release archive SHA-256: d48282ae4dab83b3dc94c16cf011bcb63835c1c02b515490e1883049c3d1f3da
