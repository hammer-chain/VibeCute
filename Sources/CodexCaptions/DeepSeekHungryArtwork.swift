import AppKit
import ImageIO
import AVFoundation

/// Two taps followed by a quiet hold. Advanced by the existing 160 ms sprite clock.
struct HungryBasinMotion {
    private(set) var frame: Int?
    private var step = 0
    private var exiting = false
    private static let entry = [0, 1, 1, 2]
    private static let loop = [3, 2, 4, 2, 3, 2, 4, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2]
    private static let exit = [2, 1, 1, 0]

    @discardableResult
    mutating func advance(requested: Bool, allowed: Bool) -> Bool {
        guard allowed else { self = Self(); return false }
        if requested {
            if exiting { step = 0; exiting = false }
            if step < Self.entry.count { frame = Self.entry[step] }
            else { frame = Self.loop[(step - Self.entry.count) % Self.loop.count] }
            step += 1
            if step >= Self.entry.count + Self.loop.count { step = Self.entry.count }
        } else if frame != nil {
            if !exiting { exiting = true; step = 0 }
            if step < Self.exit.count { frame = Self.exit[step]; step += 1 }
            else { self = Self() }
        }
        return requested && frame == 4
    }
}

/// A prepared 240 ms metal strike, triggered by the animation contact event.
/// No independent clock or asynchronous sound queue that can outlive the pose.
final class HungryBasinSound {
    private var player: AVAudioPlayer?
    private var attempted = false
    private(set) var playCount = 0
    private var enabled = true
    private var volume: Float = 0.2
    func configure(enabled: Bool, volume: Double) {
        self.enabled = enabled
        self.volume = Float(volume.isFinite ? min(1, max(0, volume)) : 0)
        player?.volume = self.volume
        if !enabled || self.volume == 0 { stop() }
    }
    func prepare() {
        guard enabled, !attempted else { return }
        attempted = true
        guard let url = Bundle.main.url(forResource: "basin-hit", withExtension: "wav")
                ?? Bundle.module.url(forResource: "basin-hit", withExtension: "wav"),
              let audio = try? AVAudioPlayer(contentsOf: url), audio.prepareToPlay() else { return }
        audio.volume = volume
        player = audio
    }
    @discardableResult func strike() -> Bool {
        guard enabled, volume > 0 else { return false }
        prepare()
        guard let player else { return false }
        player.currentTime = 0
        let played = player.play()
        if played { playCount += 1 }
        return played
    }
    func stop() { player?.stop(); player?.currentTime = 0 }
}

/// Five shared, predecoded full-body images; no per-frame image processing.
final class DeepSeekHungryArtwork {
    static let shared = DeepSeekHungryArtwork()
    let frames: [NSImage]
    var available: Bool { frames.count == 5 }
    private init() {
        frames = (0..<5).compactMap { index in
            let name = String(format: "frame-%02d", index)
            let folder = "DeepSeekThinking/Hungry"
            guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: folder)
                    ?? Bundle.module.url(forResource: name, withExtension: "png", subdirectory: folder),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0,
                    [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
            return NSImage(cgImage: image, size: NSSize(width: 384, height: 512))
        }
    }
    func draw(frame: Int, in rect: NSRect) {
        guard frames.indices.contains(frame) else { return }
        frames[frame].draw(in: rect)
    }
}
