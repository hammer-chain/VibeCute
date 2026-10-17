// Local feasibility probe for the pinned StemgenRT v0.6.1 graph.
// This tests runtime/state/timing, not separation quality or live UI latency.
#include "../Support/VocalWorker/Runtime.h"

int main(int argc, char** argv) {
    try {
        if (argc != 2) throw std::runtime_error("Usage: vocal-probe <pinned model.onnx>");
        VocalRuntime probe(argv[1]);
        std::vector<std::vector<float>> reference;
        for (size_t step = 0; step < 32; ++step) {
            probe.signal(step); probe.run(); reference.push_back(probe.next[0]);
        }
        probe.reset();
        double replayError = 0;
        for (size_t step = 0; step < 32; ++step) {
            probe.signal(step); probe.run();
            for (size_t i = 0; i < reference[step].size(); ++i)
                replayError = std::max(replayError, double(std::abs(reference[step][i] - probe.next[0][i])));
        }
        if (replayError > 1e-6) throw std::runtime_error("Reset replay mismatch");
        probe.reset();
        std::vector<float> previous(channels * hop);
        std::vector<double> timings;
        double reconstructionError = 0, processMs = 0;
        const size_t warmup = 256, measured = 4096;
        for (size_t step = 0; step < warmup + measured; ++step) {
            probe.signal(step);
            auto started = std::chrono::steady_clock::now(); probe.run();
            double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();
            if (step >= warmup) { timings.push_back(ms); processMs += ms; }
            if (step > 0) for (size_t sample = 0; sample < previous.size(); ++sample) {
                double sum = 0;
                for (size_t stem = 0; stem < sources; ++stem) sum += probe.next[0][stem * channels * hop + sample];
                reconstructionError = std::max(reconstructionError, std::abs(sum - previous[sample]));
            }
            previous = probe.data[0];
        }
        if (reconstructionError > 1e-5) throw std::runtime_error("Previous-hop reconstruction mismatch");
        std::sort(timings.begin(), timings.end());
        const double audioMs = double(measured * hop) * 1000 / 44100;
        std::cout << "{\"scope\":\"Synthetic PCM runtime feasibility; no quality or live latency claim\","
            << "\"runtime\":\"" << OrtGetApiBase()->GetVersionString() << "\",\"threads\":1,\"hopSamples\":128,\"sampleRate\":44100,"
            << "\"audioSeconds\":" << audioMs/1000 << ",\"processingMs\":" << processMs
            << ",\"realTimeFactor\":" << processMs/audioMs << ",\"hopP50Ms\":" << timings[timings.size()/2]
            << ",\"hopP95Ms\":" << timings[size_t(timings.size()*.95)] << ",\"hopP99Ms\":" << timings[size_t(timings.size()*.99)]
            << ",\"hopMaximumMs\":" << timings.back() << ",\"resetReplayMaximumError\":" << replayError
            << ",\"reconstructionMaximumError\":" << reconstructionError << "}\n";
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
