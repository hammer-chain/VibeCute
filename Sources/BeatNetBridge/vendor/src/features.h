#pragma once

#include <complex>
#include <cstdint>
#include <vector>

struct beatnet_model;

// madmom-parity LOG_SPECT features (PORTING_TO_CPP_GGML.md §1.1 / §4.2):
// 22050 Hz mono audio -> (T, 288) log-filtered spectrogram + positive
// first-order difference (diff_frames = 1), T = ceil(len(audio) / 441).
// Filterbank and Hann window are the tensors baked into the model GGUF.
// Returns row-major (T, 2*num_bands); T is written to T_out.
std::vector<float> compute_features(const float * audio, int64_t n_samples,
                                    const beatnet_model & m, int64_t & T_out);

// ---------------------------------------------------------------------------
// streaming feature extractor
// ---------------------------------------------------------------------------
// Incremental version of compute_features for chunked / live input. Frames
// are centered on their reference sample, so emitting frame t requires
// win/2 = 882 samples (40 ms) of lookahead; push() emits every frame whose
// future context is fully available, flush() emits the remaining frames
// with zero-padding at end-of-stream.
//
// Guarantee: push(chunks...) + flush() produces bit-identical output to a
// single compute_features() call on the concatenated audio, for any chunk
// sizes (compute_features is itself implemented on top of this).
struct feature_stream {
    explicit feature_stream(const beatnet_model & m);

    // append samples (22050 Hz mono); completed feature frames (288 floats
    // each) are appended to out. Returns the number of frames emitted.
    int64_t push(const float * samples, int64_t n, std::vector<float> & out);

    // end-of-stream: emit the remaining zero-padded frames so that the total
    // matches the batch frame count ceil(total_samples / hop). Returns the
    // number of frames emitted. push() must not be called afterwards
    // (use reset() to start a new stream).
    int64_t flush(std::vector<float> & out);

    void reset();

    // absolute index of the next frame to be emitted (frame t is centered
    // at sample t*hop, i.e. time t*hop/22050 s)
    int64_t next_frame() const { return next_frame_; }

private:
    void emit_frame(int64_t t, std::vector<float> & out);

    const beatnet_model * m_;
    std::vector<float> buf_;        // retained sample window
    int64_t buf_off_    = 0;        // absolute sample index of buf_[0]
    int64_t n_pushed_   = 0;        // total samples received
    int64_t next_frame_ = 0;
    bool    flushed_    = false;
    std::vector<float> prev_log_;   // previous frame's log-spectrum (for diff)

    // scratch
    std::vector<double> frame_;
    std::vector<std::complex<double>> spec_;
    std::vector<double> acc_;
};
