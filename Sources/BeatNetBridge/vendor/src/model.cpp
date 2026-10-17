#include "model.h"
#include "compute.h"

#include "ggml.h"
#include "gguf.h"

#include <cmath>
#include <cstdio>
#include <cstring>

static bool copy_tensor(struct ggml_context * ctx, const char * name, std::vector<float> & out,
                        int64_t expect_n = -1) {
    struct ggml_tensor * t = ggml_get_tensor(ctx, name);
    if (!t) {
        fprintf(stderr, "model: missing tensor %s\n", name);
        return false;
    }
    if (t->type != GGML_TYPE_F32) {
        fprintf(stderr, "model: tensor %s is not f32\n", name);
        return false;
    }
    const int64_t n = ggml_nelements(t);
    if (expect_n >= 0 && n != expect_n) {
        fprintf(stderr, "model: tensor %s has %lld elements, expected %lld\n",
                name, (long long) n, (long long) expect_n);
        return false;
    }
    out.resize(n);
    memcpy(out.data(), t->data, n * sizeof(float));
    return true;
}

static uint32_t kv_u32(struct gguf_context * g, const char * key, uint32_t def) {
    int64_t i = gguf_find_key(g, key);
    return i < 0 ? def : gguf_get_val_u32(g, i);
}

bool beatnet_model::load(const std::string & path) {
    struct ggml_context * ctx = nullptr;
    struct gguf_init_params params = {
        /*.no_alloc =*/ false,   // load tensor data into the ggml context
        /*.ctx      =*/ &ctx,
    };
    struct gguf_context * g = gguf_init_from_file(path.c_str(), params);
    if (!g) {
        fprintf(stderr, "model: failed to load gguf %s\n", path.c_str());
        return false;
    }

    dim_in      = (int32_t) kv_u32(g, "beatnetplus.dim_in",      288);
    num_cells   = (int32_t) kv_u32(g, "beatnetplus.num_cells",   150);
    num_layers  = (int32_t) kv_u32(g, "beatnetplus.num_layers",  4);
    sample_rate = (int32_t) kv_u32(g, "beatnetplus.sample_rate", 22050);
    win_length  = (int32_t) kv_u32(g, "beatnetplus.win_length",  1764);
    hop_size    = (int32_t) kv_u32(g, "beatnetplus.hop_size",    441);
    num_bands   = (int32_t) kv_u32(g, "beatnetplus.num_bands",   144);

    const int H = num_cells;
    bool ok = true;
    ok = ok && copy_tensor(ctx, "conv1.weight", conv1_w, 2 * 1 * 10);
    ok = ok && copy_tensor(ctx, "conv1.bias",   conv1_b, 2);
    ok = ok && copy_tensor(ctx, "linear0.weight", linear0_w, (int64_t) H * 278);
    ok = ok && copy_tensor(ctx, "linear0.bias",   linear0_b, H);
    ok = ok && copy_tensor(ctx, "output_linear.weight", out_w, (int64_t) 3 * H);
    ok = ok && copy_tensor(ctx, "output_linear.bias",   out_b, 3);

    lstm.resize(num_layers);
    for (int l = 0; l < num_layers && ok; l++) {
        char name[64];
        snprintf(name, sizeof(name), "lstm.weight_ih_l%d", l);
        ok = ok && copy_tensor(ctx, name, lstm[l].w_ih, (int64_t) 4 * H * H);
        snprintf(name, sizeof(name), "lstm.weight_hh_l%d", l);
        ok = ok && copy_tensor(ctx, name, lstm[l].w_hh, (int64_t) 4 * H * H);
        snprintf(name, sizeof(name), "lstm.bias_ih_l%d", l);
        ok = ok && copy_tensor(ctx, name, lstm[l].b_ih, (int64_t) 4 * H);
        snprintf(name, sizeof(name), "lstm.bias_hh_l%d", l);
        ok = ok && copy_tensor(ctx, name, lstm[l].b_hh, (int64_t) 4 * H);
    }

    const int n_bins = win_length / 2;  // 882
    ok = ok && copy_tensor(ctx, "feats.filterbank", filterbank, (int64_t) n_bins * num_bands);
    ok = ok && copy_tensor(ctx, "feats.window", window, win_length);

    gguf_free(g);
    ggml_free(ctx);
    return ok;
}

// y = W x + b, W is (n_out, n_in) row-major
static void linear(const float * W, const float * b, const float * x,
                   float * y, int n_out, int n_in) {
    for (int o = 0; o < n_out; o++) {
        const float * w = W + (size_t) o * n_in;
        float acc = b ? b[o] : 0.f;
        for (int i = 0; i < n_in; i++) acc += w[i] * x[i];
        y[o] = acc;
    }
}

static inline float sigmoidf(float x) { return 1.f / (1.f + expf(-x)); }

beatnet_model::~beatnet_model() {
    if (wbuf) ggml_backend_buffer_free(wbuf);
    if (wctx) ggml_free(wctx);
}

bool beatnet_model::init_compute(int n_threads, bool use_gpu) {
    if (compute_ready) return true;
    if (!compute_init(n_threads, use_gpu)) return false;

    const int H = num_cells;
    struct ggml_init_params ip = {
        /*.mem_size   =*/ ggml_tensor_overhead() * 32,
        /*.mem_buffer =*/ nullptr,
        /*.no_alloc   =*/ true,
    };
    wctx = ggml_init(ip);

    // ggml is column-major in ne order: a PyTorch (out, in) row-major matrix
    // maps onto ne = {in, out} with the same memory layout
    t_conv_w = ggml_new_tensor_3d(wctx, GGML_TYPE_F32, 10, 1, 2);
    t_conv_b = ggml_new_tensor_1d(wctx, GGML_TYPE_F32, 2);        // broadcast over (2, 279, T)
    t_lin0_w = ggml_new_tensor_2d(wctx, GGML_TYPE_F32, 2 * ((dim_in - 10 + 1) / 2), H);
    t_lin0_b = ggml_new_tensor_1d(wctx, GGML_TYPE_F32, H);
    t_out_w  = ggml_new_tensor_2d(wctx, GGML_TYPE_F32, H, 3);
    t_out_b  = ggml_new_tensor_1d(wctx, GGML_TYPE_F32, 3);
    for (int l = 0; l < num_layers; l++) {
        t_w_ih[l] = ggml_new_tensor_2d(wctx, GGML_TYPE_F32, H, 4 * H);
        t_bias[l] = ggml_new_tensor_1d(wctx, GGML_TYPE_F32, 4 * H);
    }

    wbuf = ggml_backend_alloc_ctx_tensors_from_buft(wctx, compute_weight_buft());
    if (!wbuf) {
        fprintf(stderr, "model: failed to allocate weight buffer\n");
        return false;
    }

    ggml_backend_tensor_set(t_conv_w, conv1_w.data(),   0, ggml_nbytes(t_conv_w));
    ggml_backend_tensor_set(t_conv_b, conv1_b.data(),   0, ggml_nbytes(t_conv_b));
    ggml_backend_tensor_set(t_lin0_w, linear0_w.data(), 0, ggml_nbytes(t_lin0_w));
    ggml_backend_tensor_set(t_lin0_b, linear0_b.data(), 0, ggml_nbytes(t_lin0_b));
    ggml_backend_tensor_set(t_out_w,  out_w.data(),     0, ggml_nbytes(t_out_w));
    ggml_backend_tensor_set(t_out_b,  out_b.data(),     0, ggml_nbytes(t_out_b));
    for (int l = 0; l < num_layers; l++) {
        ggml_backend_tensor_set(t_w_ih[l], lstm[l].w_ih.data(), 0, ggml_nbytes(t_w_ih[l]));
        std::vector<float> fused(4 * H);   // b_ih + b_hh folded into one add
        for (int i = 0; i < 4 * H; i++) fused[i] = lstm[l].b_ih[i] + lstm[l].b_hh[i];
        ggml_backend_tensor_set(t_bias[l], fused.data(), 0, ggml_nbytes(t_bias[l]));
    }

    compute_ready = true;
    return true;
}

std::vector<float> beatnet_model::infer(const float * feats, int64_t T) const {
    return compute_ready ? infer_graph(feats, T) : infer_cpu(feats, T);
}

std::vector<float> beatnet_model::infer_cpu(const float * feats, int64_t T) const {
    beatnet_lstm_state state;
    state.init(num_layers, num_cells);
    return infer_stream(feats, T, state);
}

std::vector<float> beatnet_model::infer_stream(const float * feats, int64_t T,
                                               beatnet_lstm_state & state) const {
    const int H = num_cells;          // 150
    const int D = dim_in;             // 288
    const int CONV_OUT = D - 10 + 1;  // 279
    const int POOL_OUT = CONV_OUT / 2;// 139
    const int FLAT = 2 * POOL_OUT;    // 278

    if (state.h.size() != (size_t) num_layers * H) state.init(num_layers, H);

    std::vector<float> out((size_t) T * 2);

    std::vector<float> conv((size_t) 2 * CONV_OUT);
    std::vector<float> flat(FLAT);
    std::vector<float> x(H);       // input to current LSTM layer
    std::vector<float> gates(4 * H);
    float logits[3];

    for (int64_t t = 0; t < T; t++) {
        const float * f = feats + (size_t) t * D;

        // conv1d (2 out channels, kernel 10) + ReLU
        for (int ch = 0; ch < 2; ch++) {
            const float * w = conv1_w.data() + (size_t) ch * 10;
            for (int p = 0; p < CONV_OUT; p++) {
                float acc = conv1_b[ch];
                for (int k = 0; k < 10; k++) acc += w[k] * f[p + k];
                conv[(size_t) ch * CONV_OUT + p] = acc > 0.f ? acc : 0.f;
            }
        }
        // maxpool k=2 s=2, flatten channel-major (matches torch flatten of (2,139))
        for (int ch = 0; ch < 2; ch++) {
            for (int p = 0; p < POOL_OUT; p++) {
                const float a = conv[(size_t) ch * CONV_OUT + 2 * p];
                const float b = conv[(size_t) ch * CONV_OUT + 2 * p + 1];
                flat[(size_t) ch * POOL_OUT + p] = a > b ? a : b;
            }
        }
        // linear0: 278 -> 150 (no activation)
        linear(linear0_w.data(), linear0_b.data(), flat.data(), x.data(), H, FLAT);

        // 4-layer LSTM; PyTorch gate order [i | f | g | o]
        for (int l = 0; l < num_layers; l++) {
            const lstm_layer & L = lstm[l];
            float * hl = state.h.data() + (size_t) l * H;
            float * cl = state.c.data() + (size_t) l * H;
            for (int r = 0; r < 4 * H; r++) {
                const float * wi = L.w_ih.data() + (size_t) r * H;
                const float * wh = L.w_hh.data() + (size_t) r * H;
                float acc = L.b_ih[r] + L.b_hh[r];
                for (int i = 0; i < H; i++) acc += wi[i] * x[i] + wh[i] * hl[i];
                gates[r] = acc;
            }
            for (int i = 0; i < H; i++) {
                const float ig = sigmoidf(gates[i]);
                const float fg = sigmoidf(gates[H + i]);
                const float gg = tanhf(gates[2 * H + i]);
                const float og = sigmoidf(gates[3 * H + i]);
                const float cc = fg * cl[i] + ig * gg;
                cl[i] = cc;
                hl[i] = og * tanhf(cc);
            }
            memcpy(x.data(), hl, H * sizeof(float));  // input to next layer
        }

        // output head + softmax
        linear(out_w.data(), out_b.data(),
               state.h.data() + (size_t) (num_layers - 1) * H, logits, 3, H);
        const float m = fmaxf(logits[0], fmaxf(logits[1], logits[2]));
        const float e0 = expf(logits[0] - m);
        const float e1 = expf(logits[1] - m);
        const float e2 = expf(logits[2] - m);
        const float s = e0 + e1 + e2;
        out[(size_t) t * 2 + 0] = e0 / s;  // P(beat)
        out[(size_t) t * 2 + 1] = e1 / s;  // P(downbeat)
    }
    return out;
}

// ---------------------------------------------------------------------------
// graph inference (strategy 1): batched stages on the compute backend (GPU
// when available), sequential LSTM cell update on the CPU
// ---------------------------------------------------------------------------

// sequential scan of one LSTM layer over T frames.
// gates_in: (T, 600) row-major, already = W_ih·x_t + b_ih + b_hh.
// h_out:    (T, H)   row-major hidden states of this layer.
static void lstm_scan(const float * w_hh, const float * gates_in, int64_t T, int H,
                      float * h_out) {
    std::vector<float> h(H, 0.f), c(H, 0.f), gates(4 * H);
    for (int64_t t = 0; t < T; t++) {
        const float * g0 = gates_in + (size_t) t * 4 * H;
        for (int r = 0; r < 4 * H; r++) {
            const float * wh = w_hh + (size_t) r * H;
            float acc = g0[r];
            for (int i = 0; i < H; i++) acc += wh[i] * h[i];
            gates[r] = acc;
        }
        float * ho = h_out + (size_t) t * H;
        for (int i = 0; i < H; i++) {
            const float ig = sigmoidf(gates[i]);
            const float fg = sigmoidf(gates[H + i]);
            const float gg = tanhf(gates[2 * H + i]);
            const float og = sigmoidf(gates[3 * H + i]);
            c[i] = fg * c[i] + ig * gg;
            h[i] = og * tanhf(c[i]);
            ho[i] = h[i];
        }
    }
}

std::vector<float> beatnet_model::infer_graph(const float * feats, int64_t T) const {
    const int H = num_cells;

    const size_t ctx_size = ggml_tensor_overhead() * 64 + ggml_graph_overhead();
    std::vector<float> gates((size_t) T * 4 * H);
    std::vector<float> hseq((size_t) T * H);

    // ---- graph A: conv front-end + linear0 + layer-0 input projection ----
    {
        struct ggml_init_params ip = {ctx_size, nullptr, /*no_alloc=*/true};
        struct ggml_context * ctx = ggml_init(ip);

        struct ggml_tensor * in = ggml_new_tensor_3d(ctx, GGML_TYPE_F32, dim_in, 1, T);
        ggml_set_input(in);

        // conv1d via explicit f32 im2col + matmul: ggml_conv_1d's trailing
        // reshape scrambles batched (N > 1) inputs and forces f16 im2col
        struct ggml_tensor * im = ggml_im2col(ctx, t_conv_w, in,
                                              1, 0, 0, 0, 1, 0, false,
                                              GGML_TYPE_F32);                // (10, 279, T)
        struct ggml_tensor * x = ggml_mul_mat(ctx,
            ggml_reshape_2d(ctx, t_conv_w, 10, 2), im);                      // (2, 279, T)
        x = ggml_relu(ctx, ggml_add(ctx, x, t_conv_b));
        x = ggml_cont(ctx, ggml_permute(ctx, x, 1, 0, 2, 3));               // (279, 2, T)
        x = ggml_pool_1d(ctx, x, GGML_OP_POOL_MAX, 2, 2, 0);                 // (139, 2, T)
        x = ggml_reshape_2d(ctx, x, 2 * ((dim_in - 10 + 1) / 2), T);
        x = ggml_add(ctx, ggml_mul_mat(ctx, t_lin0_w, x), t_lin0_b);         // (150, T)
        struct ggml_tensor * g = ggml_add(ctx, ggml_mul_mat(ctx, t_w_ih[0], x), t_bias[0]);
        ggml_set_output(g);                                                  // (600, T)

        struct ggml_cgraph * gf = ggml_new_graph(ctx);
        ggml_build_forward_expand(gf, g);

        graph_runner runner(GGML_DEFAULT_GRAPH_SIZE, 4);
        if (!runner.alloc(gf)) { ggml_free(ctx); return infer_cpu(feats, T); }
        // host feats are (T, 288) row-major == ggml (288, 1, T) layout
        ggml_backend_tensor_set(in, feats, 0, (size_t) T * dim_in * sizeof(float));
        if (!runner.compute(gf)) { ggml_free(ctx); return infer_cpu(feats, T); }
        ggml_backend_tensor_get(g, gates.data(), 0, gates.size() * sizeof(float));
        ggml_free(ctx);
    }

    // ---- alternate: CPU sequential scan / GPU batched input projection ----
    for (int l = 0; l < num_layers; l++) {
        if (l > 0) {
            struct ggml_init_params ip = {ctx_size, nullptr, /*no_alloc=*/true};
            struct ggml_context * ctx = ggml_init(ip);

            struct ggml_tensor * in = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, H, T);
            ggml_set_input(in);
            struct ggml_tensor * g = ggml_add(ctx, ggml_mul_mat(ctx, t_w_ih[l], in), t_bias[l]);
            ggml_set_output(g);

            struct ggml_cgraph * gf = ggml_new_graph(ctx);
            ggml_build_forward_expand(gf, g);

            graph_runner runner(GGML_DEFAULT_GRAPH_SIZE, 4);
            if (!runner.alloc(gf)) { ggml_free(ctx); return infer_cpu(feats, T); }
            ggml_backend_tensor_set(in, hseq.data(), 0, hseq.size() * sizeof(float));
            if (!runner.compute(gf)) { ggml_free(ctx); return infer_cpu(feats, T); }
            ggml_backend_tensor_get(g, gates.data(), 0, gates.size() * sizeof(float));
            ggml_free(ctx);
        }
        lstm_scan(lstm[l].w_hh.data(), gates.data(), T, H, hseq.data());
    }

    // ---- output head + softmax ----
    std::vector<float> out((size_t) T * 2);
    {
        struct ggml_init_params ip = {ctx_size, nullptr, /*no_alloc=*/true};
        struct ggml_context * ctx = ggml_init(ip);

        struct ggml_tensor * in = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, H, T);
        ggml_set_input(in);
        struct ggml_tensor * p = ggml_soft_max(ctx,
            ggml_add(ctx, ggml_mul_mat(ctx, t_out_w, in), t_out_b));         // (3, T)
        ggml_set_output(p);

        struct ggml_cgraph * gf = ggml_new_graph(ctx);
        ggml_build_forward_expand(gf, p);

        graph_runner runner(GGML_DEFAULT_GRAPH_SIZE, 4);
        if (!runner.alloc(gf)) { ggml_free(ctx); return infer_cpu(feats, T); }
        ggml_backend_tensor_set(in, hseq.data(), 0, hseq.size() * sizeof(float));
        if (!runner.compute(gf)) { ggml_free(ctx); return infer_cpu(feats, T); }
        std::vector<float> probs((size_t) T * 3);
        ggml_backend_tensor_get(p, probs.data(), 0, probs.size() * sizeof(float));
        ggml_free(ctx);
        for (int64_t t = 0; t < T; t++) {
            out[t * 2 + 0] = probs[t * 3 + 0];
            out[t * 2 + 1] = probs[t * 3 + 1];
        }
    }
    return out;
}
