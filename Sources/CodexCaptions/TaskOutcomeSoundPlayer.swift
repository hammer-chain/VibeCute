import AppKit
import AVFoundation
import CaptionCore

/// Reuses five short system sounds. Playback is asynchronous and serialized;
/// overload keeps the newest 32 pending notices rather than growing forever.
final class TaskOutcomeSoundPlayer: NSObject {
    private struct Request {
        let outcome: TaskOutcome?
        let title: String
        let turnID: String?
        let preview: Bool
        var soundName: String { outcome?.soundName ?? "Ping" }
        var label: String { outcome?.title ?? "等待回复" }
    }
    private var sounds: [String: AVAudioPCMBuffer] = [:]
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let gain = AVAudioUnitEQ(numberOfBands: 0)
    private var playbackID = 0
    private var pending: [Request] = []
    private var current: AVAudioPCMBuffer?
    private(set) var playCount = 0
    private var finishedCount = 0
    private var droppedCount = 0
    private var lastRequest: Request?
    private var lastPlayAccepted = false
    private var lastFinished = false
    private(set) var status = "等待 Codex 任务结果"
    var onChange: (() -> Void)?
    var volume: Double = 0.6 {
        didSet { updateVolume() }
    }

    override init() {
        super.init()
        engine.attach(player)
        engine.attach(gain)
        engine.connect(player, to: gain, format: nil)
        engine.connect(gain, to: engine.mainMixerNode, format: nil)
        updateVolume()
    }

    private func updateVolume() {
        let level = volume.isFinite ? min(3, max(0, volume)) : 0.6
        player.volume = Float(min(1, level))
        gain.globalGain = level > 1 ? Float(20 * log10(level)) : 0
    }

    private func stopCurrent() {
        playbackID += 1
        current = nil
        player.stop()
        engine.stop()
    }

    private var enabledOutcomes = Set(TaskOutcome.allCases)
    private var questionEnabled = true
    func setQuestionEnabled(_ enabled: Bool) {
        questionEnabled = enabled
        if !enabled {
            pending.removeAll { $0.outcome == nil }
            if lastRequest?.outcome == nil, current != nil {
                stopCurrent(); playNext()
            }
        }
    }
    func playQuestion(title: String, requestID: String, preview: Bool = false) {
        guard questionEnabled else { return }
        enqueue(Request(outcome: nil, title: title, turnID: requestID, preview: preview))
    }
    func setEnabledOutcomes(_ enabled: Set<TaskOutcome>) {
        enabledOutcomes = enabled
        pending.removeAll { !$0.preview && $0.outcome.map { !enabled.contains($0) } == true }
        if let request = lastRequest, let outcome = request.outcome, !request.preview, !enabled.contains(outcome), current != nil {
            stopCurrent(); playNext()
        }
    }

    func play(_ outcome: TaskOutcome, title: String = "试听", turnID: String? = nil, preview: Bool = false) {
        guard preview || enabledOutcomes.contains(outcome) else { return }
        enqueue(Request(outcome: outcome, title: title, turnID: turnID, preview: preview))
    }
    private func enqueue(_ request: Request) {
        if pending.count >= 32 { pending.removeFirst(); droppedCount += 1 }
        pending.append(request)
        playNext()
    }

    func stop() {
        pending.removeAll()
        stopCurrent()
        status = "任务音效已关闭"
        onChange?()
    }

    private func playNext() {
        guard current == nil else { return }
        while !pending.isEmpty {
            let request = pending.removeFirst()
            let name = request.soundName
            let sound: AVAudioPCMBuffer?
            if let cached = sounds[name] { sound = cached }
            else {
                let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
                if let file = try? AVAudioFile(forReading: url),
                   let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                 frameCapacity: AVAudioFrameCount(file.length)),
                   (try? file.read(into: buffer)) != nil {
                    sounds[name] = buffer
                    sound = buffer
                } else { sound = nil }
            }
            lastRequest = request
            lastFinished = false
            guard let sound else {
                lastPlayAccepted = false
                status = "无法载入 \(name) 音效"
                continue
            }
            playbackID += 1
            let id = playbackID
            current = sound
            do {
                engine.stop()
                engine.connect(player, to: gain, format: sound.format)
                engine.connect(gain, to: engine.mainMixerNode, format: sound.format)
                try engine.start()
                player.scheduleBuffer(sound, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self, self.playbackID == id, self.current != nil else { return }
                        self.current = nil
                        self.lastFinished = true
                        self.finishedCount += 1
                        self.playNext()
                    }
                }
                player.play()
                lastPlayAccepted = true
            } catch {
                lastPlayAccepted = false
            }
            if lastPlayAccepted {
                playCount += 1
                status = "\(request.title) · \(request.label) · \(name)"
                onChange?()
                return
            }
            current = nil
            status = "无法播放 \(name) 音效"
        }
        player.stop()
        engine.stop()
        onChange?()
    }

    var diagnostics: [String: Any] {
        ["volume": volume, "gainDB": gain.globalGain, "engineRunning": engine.isRunning,
         "cachedSoundCount": sounds.count, "playCount": playCount, "finishedCount": finishedCount, "queuedCount": pending.count,
         "droppedCount": droppedCount, "playing": current != nil && player.isPlaying,
         "outcome": lastRequest.map { $0.outcome?.rawValue ?? "question" } ?? "", "sound": lastRequest?.soundName ?? "",
         "turnID": lastRequest?.turnID ?? "", "preview": lastRequest?.preview ?? false,
         "playAccepted": lastPlayAccepted, "lastFinished": lastFinished]
    }
}
