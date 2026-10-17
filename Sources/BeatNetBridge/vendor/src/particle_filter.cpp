#include "particle_filter.h"

#include <algorithm>
#include <cfloat>
#include <cmath>

// ---------------------------------------------------------------------------
// state space (madmom BeatStateSpace / BarStateSpace with num_beats = 1)
// ---------------------------------------------------------------------------

beat_state_space::beat_state_space(double min_interval, double max_interval, int num_tempi) {
    const long lo = std::lround(min_interval);
    const long hi = std::lround(max_interval);

    std::vector<int32_t> ivals;
    for (long i = lo; i <= hi; i++) ivals.push_back((int32_t) i);
    if (num_tempi > 0 && num_tempi < (int) ivals.size()) {
        // madmom: log-spaced subsampling, rounded to unique integers
        std::vector<int32_t> sub;
        const double l0 = std::log2((double) lo), l1 = std::log2((double) hi);
        for (int k = 0; k < num_tempi; k++) {
            const double v = std::pow(2.0, l0 + (l1 - l0) * k / (num_tempi - 1));
            const int32_t r = (int32_t) std::lround(v);
            if (sub.empty() || sub.back() != r) sub.push_back(r);
        }
        ivals = sub;
    }

    num_states = 0;
    for (size_t ci = 0; ci < ivals.size(); ci++) {
        const int32_t I = ivals[ci];
        first_states.push_back(num_states);
        last_states.push_back(num_states + I - 1);
        for (int32_t k = 0; k < I; k++) {
            positions.push_back((float) k / (float) I);
            intervals.push_back(I);
            chain_of.push_back((int32_t) ci);
        }
        num_states += I;
    }
}

// ---------------------------------------------------------------------------
// particle filter
// ---------------------------------------------------------------------------

particle_filter_cascade::particle_filter_cascade(int fps_, uint32_t seed)
        : fps(fps_), T_step(1.0 / fps_), rng(seed) {
    const double min_interval = 60.0 * fps / MAX_BPM;   // ~13.95
    const double max_interval = 60.0 * fps / MIN_BPM;   // ~54.5

    st  = beat_state_space(min_interval, max_interval, NUM_TEMPI);
    st2 = beat_state_space(2, 4, 3);   // meters of 2/3/4 beats per bar

    // beat-space tempo-change transitions (madmom BarTransitionModel,
    // exponential_transition): p = exp(-lambda * |to/from - 1|), entries
    // <= eps zeroed, rows normalized
    const double eps = 2.220446049250313e-16;  // np.spacing(1)
    const size_t n_chains = st.first_states.size();
    beat_jumps.resize(n_chains);
    for (size_t ci = 0; ci < n_chains; ci++) {
        const double from_i = st.intervals[st.last_states[ci]];
        std::vector<double> p(n_chains);
        double sum = 0.0;
        for (size_t cj = 0; cj < n_chains; cj++) {
            const double to_i = st.intervals[st.first_states[cj]];
            double v = std::exp(-LAMBDA_B * std::fabs(to_i / from_i - 1.0));
            if (v <= eps) v = 0.0;
            p[cj] = v;
            sum += v;
        }
        double c = 0.0;
        for (size_t cj = 0; cj < n_chains; cj++) {
            if (p[cj] == 0.0) continue;
            c += p[cj] / sum;
            beat_jumps[ci].dest.push_back(st.first_states[cj]);
            beat_jumps[ci].cum.push_back(c);
        }
        beat_jumps[ci].cum.back() = 1.0;
    }

    // downbeat transition matrix tm2: 1-lambda_d diagonal, lambda_d/2 off
    const size_t n2 = st2.first_states.size();  // 3
    down_jumps.resize(n2);
    for (size_t i = 0; i < n2; i++) {
        double c = 0.0;
        for (size_t j = 0; j < n2; j++) {
            c += (i == j) ? (1.0 - LAMBDA_D) : LAMBDA_D / (double) (n2 - 1);
            down_jumps[i].dest.push_back(st2.first_states[j]);
            down_jumps[i].cum.push_back(c);
        }
        down_jumps[i].cum.back() = 1.0;
    }

    is_last.assign(st.num_states, 0);
    for (int32_t s : st.last_states) is_last[s] = 1;
    is_last2.assign(st2.num_states, 0);
    for (int32_t s : st2.last_states) is_last2[s] = 1;

    // particle initialization: uniform over [0, num_states - 2]
    particles.resize(PARTICLE_SIZE);
    std::uniform_int_distribution<int32_t> ib(0, st.num_states - 2);
    for (auto & p : particles) p = ib(rng);
    down_particles.resize(DOWN_PARTICLE_SIZE);
    std::uniform_int_distribution<int32_t> id(0, st2.num_states - 2);
    for (auto & p : down_particles) p = id(rng);

    path.push_back({0.f, 0});  // sentinel (Python: path = [[0, 0]])
}

int32_t particle_filter_cascade::sample_jump(const jump_table & jt) {
    std::uniform_real_distribution<double> u01(0.0, 1.0);
    const double u = u01(rng);
    const size_t i = std::lower_bound(jt.cum.begin(), jt.cum.end(), u) - jt.cum.begin();
    return jt.dest[std::min(i, jt.dest.size() - 1)];
}

// systematic/universal resampling (universal_resample in Python):
// U_j = uniform(0, 1/J) + j/J, new[j] = particles[searchsorted(cumsum, U_j)]
void particle_filter_cascade::resample(std::vector<int32_t> & parts,
                                       const std::vector<double> & weights) {
    const size_t J = parts.size();
    double sum = 0.0;
    for (double w : weights) sum += w;
    std::vector<double> cum(J);
    double c = 0.0;
    for (size_t i = 0; i < J; i++) {
        c += weights[i] / sum;
        cum[i] = c;
    }
    cum[J - 1] = 1.0;

    std::uniform_real_distribution<double> u(0.0, 1.0 / (double) J);
    std::vector<int32_t> out(J);
    for (size_t j = 0; j < J; j++) {
        const double U = u(rng) + (double) j / (double) J;
        const size_t i = std::lower_bound(cum.begin(), cum.end(), U) - cum.begin();
        out[j] = parts[std::min(i, J - 1)];
    }
    parts.swap(out);
}

const std::vector<beat_event> & particle_filter_cascade::process(const float * activations, int64_t T) {
    std::uniform_int_distribution<int> rand4(0, 3);
    std::uniform_int_distribution<int> rand_down(0, DOWN_PARTICLE_SIZE - 1);

    for (int64_t fi = 0; fi < T; fi++) {
        counter++;
        const float act_beat = activations[fi * 2 + 0];
        const float act_down = activations[fi * 2 + 1];
        // information gate: max activation, floored below the threshold
        float act = std::max(act_beat, act_down);
        if (act < IG_THRESHOLD) act = (float) OBS_FLOOR;

        // ------ beat declaration check (median particle near phase 0) ------
        {
            // gathering = int(median(particles))
            std::vector<int32_t> tmp = particles;
            const size_t n = tmp.size();
            std::nth_element(tmp.begin(), tmp.begin() + n / 2, tmp.end());
            int32_t hi2 = tmp[n / 2];
            double med;
            if (n % 2 == 1) {
                med = hi2;
            } else {
                int32_t lo2 = *std::max_element(tmp.begin(), tmp.begin() + n / 2);
                med = 0.5 * (lo2 + hi2);
            }
            const int32_t gathering = (int32_t) med;  // truncation, as int() in Python

            const int32_t chain = st.chain_of[gathering];
            const int32_t phase_idx = gathering - st.first_states[chain];
            const bool near_beat = phase_idx < (int) (0.07 / T_step) + 1;  // < 4 frames
            const double now = counter * T_step;
            const bool time_ok = (now - path.back().time) > 0.4 * T_step * st.intervals[gathering];

            if (near_beat && time_ok) {
                // ---- downbeat particles motion ----
                std::vector<int32_t> moved;
                moved.reserve(down_particles.size());
                std::vector<int32_t> lasts;
                for (int32_t p : down_particles) {
                    if (is_last2[p]) lasts.push_back(p);
                    else             moved.push_back(p + 1);
                }
                for (int32_t p : lasts) {
                    // chain index of this last state within st2.last_states
                    const int32_t arg1 = st2.chain_of[p];
                    moved.push_back(sample_jump(down_jumps[arg1]));
                }
                down_particles.swap(moved);

                // ---- downbeat particles correction ----
                if (act_down > 0.7f) {
                    for (int32_t s : st2.first_states) down_particles.push_back(s);
                }
                // obs2 = down_densities(both_activations): first states get
                // P(downbeat), the rest get P(beat) (un-gated)
                std::vector<double> w(down_particles.size());
                for (size_t i = 0; i < down_particles.size(); i++) {
                    const int32_t s = down_particles[i];
                    const bool first = st2.positions[s] == 0.f;
                    w[i] = first ? (double) act_down : (double) act_beat;
                }
                resample(down_particles, w);
                if (act_down > 0.7f) {
                    // np.delete(..., choice(DOWN_PARTICLE_SIZE, 1)): drop one
                    // random particle among the first 250
                    const int idx = rand_down(rng);
                    down_particles.erase(down_particles.begin() + idx);
                }

                // downbeat clutter: argmax of bincount (lowest state on ties)
                int32_t counts[16] = {0};
                for (int32_t p : down_particles) counts[p]++;
                int32_t down_max = 0;
                for (int32_t s = 1; s < st2.num_states; s++) {
                    if (counts[s] > counts[down_max]) down_max = s;
                }

                // ---- beat vs downbeat distinguishment ----
                const bool down_on_first = st2.positions[down_max] == 0.f;
                if (down_on_first && path.back().type != 1 && act_down > 0.4f) {
                    path.push_back({(float) now, 1});
                } else if (act > 0.4f) {
                    path.push_back({(float) now, 2});
                }
            }
        }

        // ------ beat particles motion ------
        {
            std::vector<int32_t> moved;
            moved.reserve(particles.size());
            std::vector<int32_t> lasts;
            for (int32_t p : particles) {
                if (is_last[p]) lasts.push_back(p);
                else            moved.push_back(p + 1);
            }
            for (int32_t p : lasts) {
                moved.push_back(sample_jump(beat_jumps[st.chain_of[p]]));
            }
            particles.swap(moved);
        }

        // ------ beat particles correction ------
        if (act > 0.1f) {
            if (act > 0.8f) {
                // inject particles at first states of every 6th tempo chain
                // (random offset 0..3); Python's subsequent np.delete is a
                // no-op (result unassigned), so the array stays enlarged
                const int r = rand4(rng);
                for (size_t ci = r; ci < st.first_states.size(); ci += 6) {
                    particles.push_back(st.first_states[ci]);
                }
            }
            // obs = beat_densities(act): first states (phase < 1/56) get the
            // gated activation, everything else the 0.03 floor
            std::vector<double> w(particles.size());
            for (size_t i = 0; i < particles.size(); i++) {
                const int32_t s = particles[i];
                const bool beat_state = st.positions[s] < (1.f / OBS_LAMBDA);
                w[i] = beat_state ? (double) act : OBS_FLOOR;
            }
            resample(particles, w);
        }
    }
    return path;
}
