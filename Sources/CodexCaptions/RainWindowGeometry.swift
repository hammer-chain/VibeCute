import AppKit
import CoreGraphics

final class RainWindowGeometry {
    private(set) var field = RoofField()
    private(set) var available = true
    private var lastQuery = -Double.infinity
    private(set) var queryCount = 0

    func refresh(now: Double, force: Bool = false) {
        guard force || now - lastQuery >= 0.1 else { return }
        lastQuery = now
        queryCount += 1
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            available = false
            field.windows = []
            return
        }
        available = true
        let systemOwners: Set<String> = ["Dock", "Window Server", "WindowServer", "SystemUIServer", "Control Center", "NotificationCenter", "loginwindow"]
        field.windows = info.compactMap { item in
            // Rain/character panels are above layer 0. Keep our own preferences
            // window as a roof, unlike the standalone demo with no normal windows.
            guard let layer = (item[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == 0,
                  let bounds = item[kCGWindowBounds as String] as? [String: Any],
                  let x = (bounds["X"] as? NSNumber)?.doubleValue,
                  let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                  let w = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let h = (bounds["Height"] as? NSNumber)?.doubleValue,
                  x.isFinite, y.isFinite, w.isFinite, h.isFinite,
                  w > 1, h > 1 else { return nil }
            if let alpha = (item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha <= 0 { return nil }
            // Owner app name is optional; window titles/content are never read.
            if let owner = item[kCGWindowOwnerName as String] as? String, systemOwners.contains(owner) { return nil }
            return RainRect(x: x, y: y, width: w, height: h)
        }
    }
}
