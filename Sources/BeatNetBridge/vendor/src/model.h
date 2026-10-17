#pragma once

#include <cstdint>
#include <string>
#include <vector>

// BeatNet+ CRNN (BeatNetPlusBranch) weights + baked feature constants,
// loaded from a GGUF file produced by scripts/convert_pt_to_gguf.py.
//
// Network: conv1d k=10 -> ReLU -> maxpool k=2 -> linear0 278->150 ->
// 4-layer LSTM(150) -> linear 150->3 -> softmax.
//
// Two inference paths (PORTING_TO_CPP_GGML.md §5):
//  - infer_graph(): strategy 1 — every time-batchable stage (conv front-end,
//    linear0, the four LSTM input projections W_ih·x, output head + softmax)
//    runs as ggml graphs on the GPU backend (Metal on macOS) when available;
//    only the irreducible sequential LSTM cell update runs on the CPU.
//  - infer_cpu():   strategy 2 — hand-written fp32 loops, no graphs.
// infer() picks the graph path when a compute backend was initialized.

struct lstm_layer {
    std::vector<float> w_ih;  // (600, in)  row-major, gate order [i|f|g|o]
    std::vector<float> w_hh;  // (600, 150)
    std::vector<float> b_ih;  // (600,)
    std::vector<float> b_hh;  // (600,)
};

// persistent LSTM hidden/cell state for chunked streaming inference
// (equivalent to the Python model's self.hidden / self.cell in stream mode)
struct beatnet_lstm_state {
    std::vector<float> h;  // (num_layers * num_cells)
    std::vector<float> c;  // (num_layers * num_cells)

    void init(int num_layers, int num_cells) {
        h.assign((size_t) num_layers * num_cells, 0.f);
        c.assign((size_t) num_layers * num_cells, 0.f);
    }
    void reset() {
        std::fill(h.begin(), h.end(), 0.f);
        std::fill(c.begin(), c.end(), 0.f);
    }
};

struct beatnet_model {
    // hyperparameters (from GGUF metadata)
    int32_t dim_in      = 288;
    int32_t num_cells   = 150;
    int32_t num_layers  = 4;
    int32_t sample_rate = 22050;
    int32_t win_length  = 1764;
    int32_t hop_size    = 441;
    int32_t num_bands   = 144;

    // CRNN weights (fp32, PyTorch row-major layout)
    std::vector<float> conv1_w;   // (2, 1, 10)
    std::vector<float> conv1_b;   // (2,)
    std::vector<float> linear0_w; // (150, 278)
    std::vector<float> linear0_b; // (150,)
    std::vector<float> out_w;     // (3, 150)
    std::vector<float> out_b;     // (3,)
    std::vector<lstm_layer> lstm; // 4 layers

    // baked madmom feature constants
    std::vector<float> filterbank; // (n_bins=882, num_bands) row-major
    std::vector<float> window;     // (win_length,) Hann

    // ggml weight tensors (GPU memory when a GPU backend is active)
    struct ggml_context       * wctx = nullptr;
    struct ggml_backend_buffer * wbuf = nullptr;
    struct ggml_tensor * t_conv_w = nullptr;  // (10, 1, 2)
    struct ggml_tensor * t_conv_b = nullptr;  // (1, 2, 1) for broadcast
    struct ggml_tensor * t_lin0_w = nullptr;  // (278, 150)
    struct ggml_tensor * t_lin0_b = nullptr;  // (150)
    struct ggml_tensor * t_out_w  = nullptr;  // (150, 3)
    struct ggml_tensor * t_out_b  = nullptr;  // (3)
    struct ggml_tensor * t_w_ih[8]  = {};     // per layer: (in, 600)
    struct ggml_tensor * t_bias[8]  = {};     // per layer: (600) = b_ih + b_hh
    bool compute_ready = false;

    beatnet_model() = default;
    beatnet_model(const beatnet_model &) = delete;
    beatnet_model & operator=(const beatnet_model &) = delete;
    ~beatnet_model();

    bool load(const std::string & path);

    // upload weights to the compute backend (GPU when available and
    // use_gpu is true). Must be called once before infer() uses graphs.
    bool init_compute(int n_threads, bool use_gpu);

    // feats: (T, dim_in) row-major -> activations (T, 2) [P(beat), P(downbeat)]
    std::vector<float> infer(const float * feats, int64_t T) const;
    std::vector<float> infer_cpu(const float * feats, int64_t T) const;
    std::vector<float> infer_graph(const float * feats, int64_t T) const;

    // stateful variant for chunked streaming: the LSTM hidden/cell state is
    // preserved in `state` across calls, so feeding chunks produces output
    // bit-identical to one infer_cpu() call on the concatenated features.
    // Initialize/clear the state with state.init(num_layers, num_cells).
    std::vector<float> infer_stream(const float * feats, int64_t T,
                                    beatnet_lstm_state & state) const;
};
