#include "features.h"
#include "model.h"

#include "pocketfft_hdronly.h"

#include <cmath>
#include <cstring>

// ---------------------------------------------------------------------------
// streaming extractor
// ---------------------------------------------------------------------------

feature_stream::feature_stream(const beatnet_model & m) : m_(&m) {
    const int win     = m.win_length;
    const int n_bands = m.num_bands;
    prev_log_.assign(n_bands, 0.f);
    frame_.resize(win);
    spec_.resize(win / 2 + 1);
    acc_.resize(n_bands);
}

void feature_stream::reset() {
    buf_.clear();
    buf_off_ = 0;
    n_pushed_ = 0;
    next_frame_ = 0;
    flushed_ = false;
    std::fill(prev_log_.begin(), prev_log_.end(), 0.f);
}

// compute + append the feature vector of frame t. Frame t covers absolute
// samples [t*hop - win/2, t*hop + win/2); indices outside [0, n_pushed_)
// read as zero (start-of-stream padding and, after flush, end padding).
void feature_stream::emit_frame(int64_t t, std::vector<float> & out) {
    const int win     = m_->win_length;   // 1764
    const int hop     = m_->hop_size;     // 441
    const int half    = win / 2;          // 882
    const int n_bins  = win / 2;          // magnitude bins 0..881
    const int n_bands = m_->num_bands;    // 144

    const int64_t start = t * hop - half;
    for (int i = 0; i < win; i++) {
        const int64_t j = start + i;
        const double s = (j >= 0 && j < n_pushed_) ? (double) buf_[j - buf_off_] : 0.0;
        frame_[i] = s * (double) m_->window[i];
    }

    const pocketfft::shape_t  shape      = {(size_t) win};
    const pocketfft::stride_t stride_in  = {sizeof(double)};
    const pocketfft::stride_t stride_out = {sizeof(std::complex<double>)};
    pocketfft::r2c(shape, stride_in, stride_out, 0, pocketfft::FORWARD,
                   frame_.data(), spec_.data(), 1.0);

    // magnitude -> triangular filterbank (882 x 144) -> log10(x + 1)
    std::fill(acc_.begin(), acc_.end(), 0.0);
    for (int b = 0; b < n_bins; b++) {
        const double mag = std::abs(spec_[b]);
        if (mag == 0.0) continue;
        const float * fb = m_->filterbank.data() + (size_t) b * n_bands;
        for (int k = 0; k < n_bands; k++) {
            if (fb[k] != 0.f) acc_[k] += mag * fb[k];
        }
    }

    // hstack(log_spec, positive diff vs previous frame); frame 0 diff = 0
    const size_t base = out.size();
    out.resize(base + 2 * n_bands);
    float * f = out.data() + base;
    for (int k = 0; k < n_bands; k++) {
        const float ls = (float) log10(acc_[k] + 1.0);
        f[k] = ls;
        const float d = ls - prev_log_[k];
        f[n_bands + k] = (t >= 1 && d > 0.f) ? d : 0.f;
        prev_log_[k] = ls;
    }
}

int64_t feature_stream::push(const float * samples, int64_t n, std::vector<float> & out) {
    if (flushed_ || n <= 0) return 0;
    buf_.insert(buf_.end(), samples, samples + n);
    n_pushed_ += n;

    const int hop  = m_->hop_size;
    const int half = m_->win_length / 2;

    int64_t emitted = 0;
    // frame t is complete once its future context [.., t*hop + half) arrived
    while (next_frame_ * hop + half <= n_pushed_) {
        emit_frame(next_frame_, out);
        next_frame_++;
        emitted++;
    }

    // drop samples no longer needed by any future frame
    const int64_t keep_from = next_frame_ * hop - half;
    if (keep_from > buf_off_) {
        buf_.erase(buf_.begin(), buf_.begin() + (keep_from - buf_off_));
        buf_off_ = keep_from;
    }
    return emitted;
}

int64_t feature_stream::flush(std::vector<float> & out) {
    if (flushed_) return 0;
    flushed_ = true;

    // batch frame count: ceil(total / hop)
    const int hop = m_->hop_size;
    const int64_t T_total = (n_pushed_ + hop - 1) / hop;

    int64_t emitted = 0;
    while (next_frame_ < T_total) {
        emit_frame(next_frame_, out);   // end-of-stream zero padding
        next_frame_++;
        emitted++;
    }
    buf_.clear();
    return emitted;
}

// ---------------------------------------------------------------------------
// batch API, implemented on top of the streaming extractor
// ---------------------------------------------------------------------------

std::vector<float> compute_features(const float * audio, int64_t n_samples,
                                    const beatnet_model & m, int64_t & T_out) {
    feature_stream fs(m);
    std::vector<float> feats;
    if (n_samples > 0) {
        feats.reserve((size_t) ((n_samples / m.hop_size + 2) * 2 * m.num_bands));
        fs.push(audio, n_samples, feats);
    }
    fs.flush(feats);
    T_out = (int64_t) (feats.size() / (2 * m.num_bands));
    return feats;
}
