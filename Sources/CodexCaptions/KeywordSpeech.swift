import Foundation
#if canImport(CaptionCore)
import CaptionCore
#endif

enum SpeechEngine: String, CaseIterable, Identifiable {
    case apple, whisper
    static let minimalRelease = Bundle.main.object(forInfoDictionaryKey: "CaptionsMinimalRelease") as? Bool == true
    static var available: [Self] { minimalRelease ? [.apple] : allCases }
    var id: String { rawValue }
    var title: String { self == .apple ? "Apple Speech" : "whisper.cpp" }
}

protocol KeywordSpeechBackend: AnyObject {
    var onStatus: ((String, Bool) -> Void)? { get set }
    var onTranscript: ((String, SpeechProgress) -> Void)? { get set }
    var onProgress: ((SpeechProgress) -> Void)? { get set }
    var onKeyword: ((SpeechKeywordMatch, Bool) -> Void)? { get set }
    func setEnabled(_ enabled: Bool)
    func submit(_ samples: [Float], sampleRate: Double, startedAt: TimeInterval)
    func resetStream()
}

extension JapaneseKeywordSpeech: KeywordSpeechBackend {}

/// Control/callbacks run on main; the audio queue only snapshots the backend.
/// Each activation owns a new instance, so late callbacks cannot cross engines.
final class KeywordSpeech {
    var onStatus: ((String, Bool) -> Void)?
    var onTranscript: ((String, SpeechProgress) -> Void)?
    var onProgress: ((SpeechProgress) -> Void)?
    var onKeyword: ((SpeechKeywordMatch, Bool) -> Void)?
    private let lock = NSLock()
    private var backend: KeywordSpeechBackend?
    private var generation = 0
    private var engine = SpeechEngine.apple
    private var modelPath = ""
    private var enabled = false
    private var audioActive = false
    private var ready = false
    private struct Chunk { let samples: [Float]; let rate: Double; let start: Double }
    private var startup: [Chunk] = []
    private let makeBackend: (SpeechEngine, String) -> KeywordSpeechBackend

    init(backendFactory: ((SpeechEngine, String) -> KeywordSpeechBackend)? = nil) {
        makeBackend = backendFactory ?? { engine, path in
            if engine == .apple { return JapaneseKeywordSpeech() }
            return WhisperKeywordSpeech(modelPath: path)
        }
    }

    func setEnabled(_ active: Bool, engine: SpeechEngine = .apple, modelPath: String = "") {
        guard active != enabled || engine != self.engine || modelPath != self.modelPath else { return }
        lock.lock(); enabled = active; startup.removeAll(); lock.unlock()
        self.engine = engine; self.modelPath = modelPath
        replaceBackend()
    }

    /// Main-thread control; capture continues while both recognition models stop.
    func setAudioActive(_ active: Bool) {
        guard audioActive != active else { return }
        audioActive = active
        replaceBackend()
    }

    private func replaceBackend() {
        generation += 1
        let token = generation
        lock.lock(); let old = backend; backend = nil; ready = false
        if !enabled || !audioActive { startup.removeAll() }
        lock.unlock()
        old?.setEnabled(false)
        onProgress?(SpeechProgress())
        guard enabled else { onStatus?("\(engine.title) 已关闭", false); return }
        guard audioActive else { onStatus?("纯静音 / 等待声音 · \(engine.title) 模型已停止", false); return }
        onStatus?("\(engine.title) 正在启动…", false)
        let next = makeBackend(engine, modelPath)
        next.onStatus = { [weak self] text, running in
            guard let self, self.generation == token else { return }
            self.lock.lock()
            let buffered = running ? self.startup : []
            if running { self.startup.removeAll() }
            let current = self.backend
            // Merge adjacent callback-sized packets before replay. Backends bound
            // their pending queue to eight inputs; replaying 80 tiny chunks drops onset.
            var merged: [Chunk] = []
            for chunk in buffered {
                if let last = merged.last, last.rate == chunk.rate,
                   abs(last.start + Double(last.samples.count) / last.rate - chunk.start) < 0.001,
                   last.samples.count + chunk.samples.count <= Int(last.rate / 2) {
                    merged[merged.count - 1] = Chunk(samples: last.samples + chunk.samples, rate: last.rate, start: last.start)
                } else { merged.append(chunk) }
            }
            for chunk in merged { current?.submit(chunk.samples, sampleRate: chunk.rate, startedAt: chunk.start) }
            self.ready = running; self.lock.unlock()
            self.onStatus?(text, running)
        }
        next.onProgress = { [weak self] value in
            guard let self, self.generation == token else { return }; self.onProgress?(value)
        }
        next.onTranscript = { [weak self] text, value in
            guard let self, self.generation == token else { return }; self.onTranscript?(text, value)
        }
        next.onKeyword = { [weak self] value, audible in
            guard let self, self.generation == token else { return }; self.onKeyword?(value, audible)
        }
        lock.lock(); backend = next; lock.unlock()
        next.setEnabled(true)
    }

    func submit(_ samples: [Float], sampleRate: Double, startedAt: TimeInterval) {
        guard !samples.isEmpty, sampleRate.isFinite, (16_000...192_000).contains(sampleRate),
              samples.count <= Int(sampleRate), startedAt.isFinite else { return }
        lock.lock()
        guard enabled else { lock.unlock(); return }
        let current = ready ? backend : nil
        if current == nil {
            startup.append(Chunk(samples: samples, rate: sampleRate, start: startedAt))
            let end = startedAt + Double(samples.count) / sampleRate
            startup.removeAll { end - $0.start > 2 }
            if startup.count > 256 { startup.removeFirst(startup.count - 256) }
        }
        lock.unlock()
        current?.submit(samples, sampleRate: sampleRate, startedAt: startedAt)
    }
    func resetStream() {
        lock.lock(); let current = backend; lock.unlock(); current?.resetStream()
    }
}
