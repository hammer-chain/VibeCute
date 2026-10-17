#pragma once

#include <cstdint>
#include <random>
#include <vector>

// C++ port of BeatNetPlus.particle_filtering_cascade.particle_filter_cascade
// (causal cascade particle filter over madmom bar-pointer state spaces).
// See PORTING_TO_CPP_GGML.md §1.3 / §6.
//
// RNG streams differ from numpy, so output is compared with the Python
// reference by 70 ms-tolerance F-measure, not bit-exactly.

struct beat_event {
    float time;   // seconds
    int   type;   // 1 = downbeat, 2 = beat
};

// madmom BarStateSpace with num_beats = 1
struct beat_state_space {
    int32_t num_states = 0;
    std::vector<float>   positions;    // phase in [0, 1)
    std::vector<int32_t> intervals;    // tempo (frames per beat) per state
    std::vector<int32_t> first_states; // per tempo chain
    std::vector<int32_t> last_states;  // per tempo chain
    std::vector<int32_t> chain_of;     // state -> tempo chain index

    beat_state_space() = default;
    beat_state_space(double min_interval, double max_interval, int num_tempi);
};

struct particle_filter_cascade {
    // constants (mirror the Python class attributes)
    static constexpr int    PARTICLE_SIZE      = 1500;
    static constexpr int    DOWN_PARTICLE_SIZE = 250;
    static constexpr double MIN_BPM            = 55.0;
    static constexpr double MAX_BPM            = 215.0;
    static constexpr int    NUM_TEMPI          = 300;
    static constexpr double LAMBDA_B           = 60.0;
    static constexpr double LAMBDA_D           = 0.1;
    static constexpr int    OBS_LAMBDA         = 56;    // "B56"
    static constexpr double IG_THRESHOLD      = 0.4;
    static constexpr double OBS_FLOOR         = 0.03;

    explicit particle_filter_cascade(int fps = 50, uint32_t seed = 1);

    // feed activations (T, 2) = [P(beat), P(downbeat)] per frame; may be
    // called repeatedly (stateful/causal). Returns all events so far.
    const std::vector<beat_event> & process(const float * activations, int64_t T);

    // --- internal state ---
    int    fps;
    double T_step;                       // 1 / fps
    int64_t counter = -1;

    beat_state_space st;                 // beat space (1449 states)
    beat_state_space st2;                // downbeat space (9 states)

    // per-chain transitions from a chain's last state -> first states
    struct jump_table {
        std::vector<int32_t> dest;       // destination states
        std::vector<double>  cum;        // cumulative probabilities
    };
    std::vector<jump_table> beat_jumps;  // per beat-space chain
    std::vector<jump_table> down_jumps;  // per downbeat-space chain (tm2 rows)

    std::vector<uint8_t> is_last;        // beat space:  state -> is last state
    std::vector<uint8_t> is_last2;       // down space:  state -> is last state

    std::vector<int32_t> particles;      // beat particles (state indices)
    std::vector<int32_t> down_particles; // downbeat particles

    std::vector<beat_event> path;

    std::mt19937 rng;

private:
    void resample(std::vector<int32_t> & parts, const std::vector<double> & weights);
    int32_t sample_jump(const jump_table & jt);
};
