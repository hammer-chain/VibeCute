#include "compute.h"

#include "ggml-cpu.h"

#include <cstdio>
#include <cstdlib>
#include <vector>

struct compute_env {
    bool initialized = false;
    ggml_backend_t gpu = nullptr;
    ggml_backend_t cpu = nullptr;
    std::vector<ggml_backend_t> backends;  // [gpu?, accel..., cpu]
    char gpu_name[128] = "none";
};

static compute_env g_env;

bool compute_init(int n_threads, bool use_gpu) {
    if (g_env.initialized) return true;

    if (use_gpu && getenv("BEATNETPLUS_CPU") == nullptr) {
        ggml_backend_dev_t dev = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_GPU);
        if (dev) {
            g_env.gpu = ggml_backend_dev_init(dev, nullptr);
            if (g_env.gpu) {
                snprintf(g_env.gpu_name, sizeof(g_env.gpu_name), "%s (%s)",
                         ggml_backend_dev_name(dev), ggml_backend_dev_description(dev));
            }
        }
        if (!g_env.gpu) {
            fprintf(stderr, "compute: no GPU backend available, using CPU\n");
        }
    }

    g_env.cpu = ggml_backend_cpu_init();
    ggml_backend_cpu_set_n_threads(g_env.cpu, n_threads);

    if (g_env.gpu) g_env.backends.push_back(g_env.gpu);

    // accelerator backends (e.g. BLAS) speed up large f32 matmuls when no GPU
    // is in front of them in the scheduler priority order
    for (size_t i = 0; i < ggml_backend_dev_count(); i++) {
        ggml_backend_dev_t dev = ggml_backend_dev_get(i);
        if (ggml_backend_dev_type(dev) == GGML_BACKEND_DEVICE_TYPE_ACCEL) {
            ggml_backend_t b = ggml_backend_dev_init(dev, nullptr);
            if (b) g_env.backends.push_back(b);
        }
    }

    g_env.backends.push_back(g_env.cpu);

    g_env.initialized = true;
    return true;
}

void compute_free() {
    if (!g_env.initialized) return;
    for (ggml_backend_t b : g_env.backends) ggml_backend_free(b);
    g_env = compute_env();
}

bool compute_has_gpu() {
    return g_env.gpu != nullptr;
}

const char * compute_gpu_name() {
    return g_env.gpu_name;
}

ggml_backend_buffer_type_t compute_weight_buft() {
    compute_init(4, true);  // lazy default
    return ggml_backend_get_default_buffer_type(g_env.backends[0]);
}

graph_runner::graph_runner(size_t graph_size, int n_threads) {
    compute_init(n_threads, true);
    sched = ggml_backend_sched_new(g_env.backends.data(), nullptr,
                                   (int) g_env.backends.size(), graph_size,
                                   /*parallel=*/false, /*op_offload=*/true);
}

graph_runner::~graph_runner() {
    if (sched) ggml_backend_sched_free(sched);
}

bool graph_runner::alloc(struct ggml_cgraph * gf) {
    if (!ggml_backend_sched_alloc_graph(sched, gf)) {
        fprintf(stderr, "graph_runner: allocation failed\n");
        return false;
    }
    return true;
}

bool graph_runner::compute(struct ggml_cgraph * gf) {
    return ggml_backend_sched_graph_compute(sched, gf) == GGML_STATUS_SUCCESS;
}
