#if VIBECUTE_RELEASE
import Foundation
import CaptionCore

// Compatibility surfaces only. Production contains no speech framework, model,
// subprocess, audio buffers or polling implementation for these removed features.
enum SpeechEngine: String, CaseIterable, Identifiable {
    case apple, whisper
    static let minimalRelease = true
    static let available: [Self] = []
    var id: String { rawValue }
    var title: String { "未包含语音关键词" }
}
final class KeywordSpeech {
    var onStatus: ((String, Bool) -> Void)?
    var onTranscript: ((String, SpeechProgress) -> Void)?
    var onProgress: ((SpeechProgress) -> Void)?
    var onKeyword: ((SpeechKeywordMatch, Bool) -> Void)?
    func setEnabled(_ active: Bool, engine: SpeechEngine = .apple, modelPath: String = "") {}
    func setAudioActive(_ active: Bool) {}
    func submit(_ samples: [Float], sampleRate: Double, startedAt: TimeInterval) {}
    func resetStream() {}
}
enum WhisperKeywordSpeech {
    static let bundledModelPath = ""
    static let windowSeconds = 0
}
final class NowPlayingMonitor {
    var onUpdate: ((NowPlayingTrack?, String) -> Void)?
    func setEnabled(_ enabled: Bool) {}
    func stop() {}
    func refresh() {}
}
#endif
