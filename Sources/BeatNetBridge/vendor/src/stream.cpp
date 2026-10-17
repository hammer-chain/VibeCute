#include "stream.h"

beatnet_stream::beatnet_stream(const beatnet_model & m, int fps, uint32_t seed)
        : m_(&m), fps_(fps), seed_(seed), feats_(m), pf_(fps, seed) {
    lstm_.init(m.num_layers, m.num_cells);
}

void beatnet_stream::reset() {
    feats_.reset();
    lstm_.reset();
    pf_ = particle_filter_cascade(fps_, seed_);
    n_reported_ = 1;
    beats_.clear();
}

std::vector<beat_event> beatnet_stream::process_frames(const std::vector<float> & feats, int64_t T) {
    std::vector<beat_event> fresh;
    if (T <= 0) return fresh;

    const std::vector<float> acts = m_->infer_stream(feats.data(), T, lstm_);
    const std::vector<beat_event> & path = pf_.process(acts.data(), T);

    for (size_t i = n_reported_; i < path.size(); i++) {
        fresh.push_back(path[i]);
        beats_.push_back(path[i]);
    }
    n_reported_ = path.size();
    return fresh;
}

std::vector<beat_event> beatnet_stream::push(const float * samples, int64_t n) {
    fbuf_.clear();
    const int64_t T = feats_.push(samples, n, fbuf_);
    return process_frames(fbuf_, T);
}

std::vector<beat_event> beatnet_stream::flush() {
    fbuf_.clear();
    const int64_t T = feats_.flush(fbuf_);
    return process_frames(fbuf_, T);
}
