#pragma once

#include "features.h"
#include "model.h"
#include "particle_filter.h"

#include <cstdint>
#include <vector>

// ---------------------------------------------------------------------------
// end-to-end streaming beat tracker: 22050 Hz mono samples in, beats out
// ---------------------------------------------------------------------------
// Combines the three stateful pieces (feature ring buffer, persistent LSTM
// hidden/cell state, causal particle filter) so a live source — microphone,
// network, or a file fed chunk by chunk — can be processed incrementally.
//
// Guarantee: for a finite input, push(chunks...) + flush() emits exactly the
// same beat list as the batch pipeline (compute_features -> infer_cpu ->
// particle_filter_cascade::process), for any chunk sizes.
//
// Latency: a frame becomes available win/2 = 882 samples (40 ms) after its
// reference time (centered analysis window), plus the particle filter's own
// beat-confirmation delay.
//
// The model must outlive the stream. The NN runs on the scalar CPU path
// (per-chunk GPU graph launches would be pure overhead at this model size).
struct beatnet_stream {
    explicit beatnet_stream(const beatnet_model & m, int fps = 50, uint32_t seed = 1);

    // feed any number of samples; returns beats newly detected by this call
    std::vector<beat_event> push(const float * samples, int64_t n);

    // end-of-stream: process the final zero-padded frames; returns the last
    // newly detected beats. push() must not be called afterwards.
    std::vector<beat_event> flush();

    // all beats detected so far
    const std::vector<beat_event> & beats() const { return beats_; }

    // start a new stream (clears all state)
    void reset();

private:
    std::vector<beat_event> process_frames(const std::vector<float> & feats, int64_t T);

    const beatnet_model * m_;
    int      fps_;
    uint32_t seed_;

    feature_stream          feats_;
    beatnet_lstm_state      lstm_;
    particle_filter_cascade pf_;
    size_t                  n_reported_ = 1;   // skip the PF's [0,0] sentinel
    std::vector<beat_event> beats_;
    std::vector<float>      fbuf_;             // scratch: feature frames
};
