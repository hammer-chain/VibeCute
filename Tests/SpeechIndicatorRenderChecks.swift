import AppKit
import SwiftUI
import CaptionCore

@main enum SpeechIndicatorRenderChecks {
    static func main() throws {
        _ = NSApplication.shared
        let folder = URL(fileURLWithPath: "output/whisper/keyword-indicators")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let states: [Set<JapaneseKiraKeyword>] = [[]] + JapaneseKiraKeyword.allCases.map { [$0] } + [Set(JapaneseKiraKeyword.allCases)]
        for (index, keywords) in states.enumerated() {
            let root = SpeechKeywordIndicators(highlighted: keywords)
                .padding(12).frame(width: 336, height: 98, alignment: .leading)
                .background(Color(NSColor.windowBackgroundColor))
            let host = NSHostingView(rootView: root)
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = NSRect(x: 0, y: 0, width: 336, height: 98)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host; host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if !keywords.isEmpty {
                var orange = 0
                for x in 0..<bitmap.pixelsWide {
                    for y in 0..<bitmap.pixelsHigh {
                        guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                        if c.redComponent > c.greenComponent * 1.25 && c.greenComponent > c.blueComponent * 1.3 { orange += 1 }
                    }
                }
                precondition(orange > 50, "Matched target must have a visible colored highlight")
            }
            try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("\(index).png"))
            window.contentView = nil
        }
        print("PASS: actual SwiftUI target indicators rendered for idle and all four matched words")
    }
}
