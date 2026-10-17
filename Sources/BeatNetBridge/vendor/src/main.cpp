#include "audio.h"
#include "common.h"
#include "compute.h"
#include "features.h"
#include "model.h"
#include "particle_filter.h"
#include "stream.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

static void usage(const char * prog) {
    fprintf(stderr,
            "usage: %s --weights model.gguf [options] audio.{mp3,wav,npy}\n"
            "\n"
            "options:\n"
            "  --weights PATH   model gguf (from scripts/convert_pt_to_gguf.py)\n"
            "  --device DEV     gpu (default; Metal/Vulkan/CUDA, CPU fallback) or cpu\n"
            "  --json           emit a JSON document instead of text lines\n"
            "  -o PATH          write the output to PATH instead of stdout\n"
            "  --stream         incremental (chunked) processing; beats print as\n"
            "                   they are detected. With audio '-', reads raw f32le\n"
            "                   mono 22050 Hz PCM from stdin (pipe a mic or file\n"
            "                   through ffmpeg/sox); with a file, simulates a live\n"
            "                   stream in 100 ms chunks\n"
            "  --dump-feats P   save features to P (npy, T x 288)\n"
            "  --dump-acts P    save NN activations to P (npy, T x 2)\n"
            "  --quiet          suppress progress on stderr\n"
            "\n"
            "text output:  <time_seconds> <type>  (1 = downbeat, 2 = beat)\n"
            "json output:  {audio, sample_rate, duration_seconds, fps, bpm,\n"
            "               num_beats, num_downbeats, beats: [{time, type}]}\n"
            "\n"
            "stream examples:\n"
            "  ffmpeg -i song.mp3 -f f32le -ac 1 -ar 22050 - 2>/dev/null | \\\n"
            "      %s --weights model.gguf --stream -\n"
            "  sox -d -t raw -e float -b 32 -c 1 -r 22050 - 2>/dev/null | \\\n"
            "      %s --weights model.gguf --stream -      # live microphone\n",
            prog, prog, prog);
}

// minimal JSON string escaping (for the audio path)
static std::string json_escape(const std::string & s) {
    std::string out;
    for (char c : s) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n";  break;
            case '\t': out += "\\t";  break;
            default:
                if ((unsigned char) c < 0x20) {
                    char buf[8];
                    snprintf(buf, sizeof(buf), "\\u%04x", c);
                    out += buf;
                } else {
                    out += c;
                }
        }
    }
    return out;
}

static std::string format_json(const std::string & audio_path, double duration_s,
                               int sample_rate, int fps,
                               const std::vector<beat_event> & beats) {
    int n_down = 0;
    std::vector<float> times;
    for (const beat_event & b : beats) {
        times.push_back(b.time);
        n_down += b.type == 1;
    }

    // tempo estimate: 60 / median inter-beat interval
    double bpm = 0.0;
    if (times.size() >= 2) {
        std::vector<float> ibis;
        for (size_t i = 1; i < times.size(); i++) ibis.push_back(times[i] - times[i - 1]);
        std::sort(ibis.begin(), ibis.end());
        const size_t n = ibis.size();
        const double med = n % 2 ? ibis[n / 2] : 0.5 * (ibis[n / 2 - 1] + ibis[n / 2]);
        if (med > 0) bpm = 60.0 / med;
    }

    std::string out;
    out.reserve(64 * beats.size() + 512);
    char buf[256];
    snprintf(buf, sizeof(buf),
             "{\n"
             "  \"audio\": \"%s\",\n"
             "  \"sample_rate\": %d,\n"
             "  \"duration_seconds\": %.3f,\n"
             "  \"fps\": %d,\n",
             json_escape(audio_path).c_str(), sample_rate, duration_s, fps);
    out += buf;
    if (bpm > 0) {
        snprintf(buf, sizeof(buf), "  \"bpm\": %.1f,\n", bpm);
    } else {
        snprintf(buf, sizeof(buf), "  \"bpm\": null,\n");
    }
    out += buf;
    snprintf(buf, sizeof(buf),
             "  \"num_beats\": %zu,\n"
             "  \"num_downbeats\": %d,\n"
             "  \"beats\": [",
             times.size(), n_down);
    out += buf;
    for (size_t i = 0; i < beats.size(); i++) {
        snprintf(buf, sizeof(buf), "%s\n    {\"time\": %.3f, \"type\": \"%s\"}",
                 i > 0 ? "," : "", beats[i].time,
                 beats[i].type == 1 ? "downbeat" : "beat");
        out += buf;
    }
    out += !beats.empty() ? "\n  ]\n}\n" : "]\n}\n";
    return out;
}

// incremental processing of a live or simulated stream. Returns the number
// of audio samples consumed, with detected beats printed as they appear
// (text mode) and collected into all_beats.
static int64_t run_stream(beatnet_stream & bs, const std::string & audio_path,
                          int sample_rate, bool print_live,
                          std::vector<beat_event> & all_beats) {
    const int64_t CHUNK = sample_rate / 10;  // 100 ms
    int64_t total = 0;

    auto report = [&](const std::vector<beat_event> & fresh) {
        for (const beat_event & e : fresh) {
            all_beats.push_back(e);
            if (print_live) {
                printf("%.3f %d\n", e.time, e.type);
                fflush(stdout);
            }
        }
    };

    if (audio_path == "-") {
        // raw f32le mono PCM at the model sample rate from stdin
#ifdef _WIN32
        _setmode(_fileno(stdin), _O_BINARY);  // no CRLF mangling of raw floats
#endif
        std::vector<float> buf(CHUNK);
        size_t n;
        while ((n = fread(buf.data(), sizeof(float), CHUNK, stdin)) > 0) {
            report(bs.push(buf.data(), (int64_t) n));
            total += n;
        }
    } else {
        // simulate a live stream from a decoded file
        std::vector<float> audio = load_audio(audio_path, sample_rate);
        if (audio.empty()) return -1;
        for (int64_t off = 0; off < (int64_t) audio.size(); off += CHUNK) {
            const int64_t n = std::min<int64_t>(CHUNK, audio.size() - off);
            report(bs.push(audio.data() + off, n));
            total += n;
        }
    }
    report(bs.flush());
    return total;
}

int main(int argc, char ** argv) {
    std::string weights, audio_path, dump_feats, dump_acts, out_path, device = "gpu";
    bool quiet = false, json = false, stream = false;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--weights") && i + 1 < argc) weights = argv[++i];
        else if (!strcmp(argv[i], "--device") && i + 1 < argc) device = argv[++i];
        else if (!strcmp(argv[i], "--json")) json = true;
        else if (!strcmp(argv[i], "--stream")) stream = true;
        else if (!strcmp(argv[i], "-o") && i + 1 < argc) out_path = argv[++i];
        else if (!strcmp(argv[i], "--dump-feats") && i + 1 < argc) dump_feats = argv[++i];
        else if (!strcmp(argv[i], "--dump-acts") && i + 1 < argc) dump_acts = argv[++i];
        else if (!strcmp(argv[i], "--quiet")) quiet = true;
        else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) { usage(argv[0]); return 0; }
        else audio_path = argv[i];
    }
    if (weights.empty() || audio_path.empty()) {
        usage(argv[0]);
        return 1;
    }

    const auto t0 = std::chrono::steady_clock::now();

    beatnet_model model;
    if (!model.load(weights)) return 1;

    if (device != "cpu") {
        model.init_compute(4, /*use_gpu=*/true);
        if (!quiet) fprintf(stderr, "device: %s\n",
                            compute_has_gpu() ? compute_gpu_name() : "cpu (graphs)");
    } else if (!quiet) {
        fprintf(stderr, "device: cpu (scalar)\n");
    }

    std::vector<beat_event> result;   // detected beats (no sentinel)
    double  duration_s = 0.0;
    int64_t T = 0;

    if (stream) {
        // incremental mode: feature ring buffer + persistent LSTM state +
        // causal PF; NN runs on the scalar CPU path (per-chunk GPU graph
        // launches are pure overhead at this model size)
        beatnet_stream bs(model, 50, 1);
        const bool print_live = !json && out_path.empty();
        const int64_t n = run_stream(bs, audio_path, model.sample_rate, print_live, result);
        if (n < 0) return 1;
        duration_s = (double) n / model.sample_rate;
        T = (n + model.hop_size - 1) / model.hop_size;
    } else {
        std::vector<float> audio = load_audio(audio_path, model.sample_rate);
        if (audio.empty()) return 1;
        duration_s = (double) audio.size() / model.sample_rate;
        if (!quiet) fprintf(stderr, "audio: %.1f s @ %d Hz\n", duration_s, model.sample_rate);

        std::vector<float> feats = compute_features(audio.data(), audio.size(), model, T);
        if (!dump_feats.empty()) npy_save(dump_feats, feats.data(), {T, 2 * model.num_bands});

        std::vector<float> acts = model.infer(feats.data(), T);
        if (!dump_acts.empty()) npy_save(dump_acts, acts.data(), {T, 2});

        particle_filter_cascade pf(50, 1);
        const auto & path = pf.process(acts.data(), T);
        result.assign(path.begin() + 1, path.end());  // drop the [0,0] sentinel
    }

    // format + write the result (in live text mode it was already printed)
    std::string output;
    if (json) {
        output = format_json(audio_path, duration_s, model.sample_rate, 50, result);
    } else if (!(stream && out_path.empty())) {
        char buf[64];
        for (const beat_event & e : result) {
            snprintf(buf, sizeof(buf), "%.3f %d\n", e.time, e.type);
            output += buf;
        }
    }

    if (out_path.empty()) {
        fputs(output.c_str(), stdout);
    } else {
        FILE * f = fopen(out_path.c_str(), "w");
        if (!f) {
            fprintf(stderr, "cannot write %s\n", out_path.c_str());
            return 1;
        }
        fputs(output.c_str(), f);
        fclose(f);
        if (!quiet) fprintf(stderr, "wrote %s\n", out_path.c_str());
    }

    if (!quiet) {
        const auto t1 = std::chrono::steady_clock::now();
        const double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
        int n_down = 0;
        for (const beat_event & e : result) n_down += e.type == 1;
        fprintf(stderr, "frames: %lld, beats: %zu (downbeats: %d), %.0f ms total\n",
                (long long) T, result.size(), n_down, ms);
    }
    return 0;
}
