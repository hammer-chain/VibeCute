#pragma once

#include <cstdint>
#include <string>
#include <vector>

// ---------------------------------------------------------------------------
// minimal .npy (fp32, C-order) reader/writer for parity fixtures
// ---------------------------------------------------------------------------

struct npy_array {
    std::vector<int64_t> shape;
    std::vector<float>   data;

    int64_t n_elements() const {
        int64_t n = 1;
        for (auto s : shape) n *= s;
        return n;
    }
};

bool npy_load(const std::string & path, npy_array & out);
bool npy_save(const std::string & path, const float * data, const std::vector<int64_t> & shape);

// max |a-b| over n elements
float max_abs_diff(const float * a, const float * b, int64_t n);
