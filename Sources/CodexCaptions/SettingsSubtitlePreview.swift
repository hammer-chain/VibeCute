import AppKit
import SwiftUI

/// A bounded subtitle-only snapshot, reused until font or background changes.
final class SettingsPreviewImageView: NSImageView {
  // Bitmap dimensions must not impose a minimum height on the preview slot.
  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
  }
}

struct SettingsSubtitlePreview: NSViewRepresentable {
  var fontSize: Double
  var opacity: Double
  final class Coordinator { var key = "" }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSImageView {
    let view = SettingsPreviewImageView()
    view.identifier = NSUserInterfaceItemIdentifier("settings-subtitle-preview")
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    view.imageScaling = .scaleProportionallyUpOrDown
    view.setAccessibilityLabel("字幕气泡预览")
    return view
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSImageView, context: Context) -> NSSize? {
    NSSize(width: proposal.width ?? 600, height: proposal.height ?? 220)
  }
  func updateNSView(_ view: NSImageView, context: Context) {
    let key = "\(fontSize)|\(opacity)"
    guard context.coordinator.key != key else { return }
    context.coordinator.key = key
    let bubble = SubtitleView(frame: NSRect(x: 0, y: 0, width: 560, height: 160))
    bubble.mode = .bubble
    bubble.layoutScale = 1
    bubble.fontSize = fontSize
    bubble.backdrop = opacity
    bubble.showsCaptionHeader = false
    bubble.text = "这是当前字幕气泡的预览。\n字号和底色会随设置实时更新。"
    bubble.sideTailTarget = NSPoint(x: -10, y: 80)
    let bubbleHeight = bubble.height(for: 560)
    bubble.setFrameSize(NSSize(width: 560, height: bubbleHeight))
    bubble.sideTailTarget = NSPoint(x: -10, y: bubbleHeight / 2)
    let imageHeight = max(220, bubbleHeight + 40)
    let image = NSImage(size: NSSize(width: 600, height: imageHeight))
    image.lockFocus()
    NSGraphicsContext.current?.saveGraphicsState()
    NSAffineTransform.translatePreview(x: 20, y: (imageHeight - bubbleHeight) / 2)
    bubble.draw(bubble.bounds)
    NSGraphicsContext.current?.restoreGraphicsState()
    image.unlockFocus()
    view.image = image
  }
}
extension NSAffineTransform {
  fileprivate static func translatePreview(x: CGFloat, y: CGFloat) {
    let transform = NSAffineTransform()
    transform.translateX(by: x, yBy: y)
    transform.concat()
  }
}
