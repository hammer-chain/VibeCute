import AppKit

/// Store bottom-center anchors relative to the selected display's visible area.
/// Character scaling does not change that anchor, and display origins may move.
final class CharacterPositionStore {
    private let defaults: UserDefaults
    private let key = "characterPositions"

    init(defaults: UserDefaults) { self.defaults = defaults }

    func anchor(for source: String, in area: NSRect) -> NSPoint? {
        guard let row = defaults.dictionary(forKey: key)?[source] as? [String: Double],
              let x = row["x"], let y = row["y"], x.isFinite, y.isFinite else { return nil }
        return NSPoint(x: area.minX + x, y: area.minY + y)
    }

    func save(anchor: NSPoint, source: String, in area: NSRect) {
        guard area.width > 0, area.height > 0, anchor.x.isFinite, anchor.y.isFinite else { return }
        let row = ["x": Double(anchor.x - area.minX), "y": Double(anchor.y - area.minY)]
        var positions = defaults.dictionary(forKey: key) ?? [:]
        guard positions[source] as? [String: Double] != row else { return }
        positions[source] = row
        defaults.set(positions, forKey: key)
    }

    func flush() { defaults.synchronize() }

    static func selectedScreen(defaults: UserDefaults, screens: [NSScreen]) -> Int {
        if let id = defaults.string(forKey: "selectedDisplayID"),
           let index = screens.firstIndex(where: { displayID($0) == id }) { return index }
        return min(max(0, defaults.integer(forKey: "screenIndex")), max(0, screens.count - 1))
    }

    static func saveScreen(_ index: Int, defaults: UserDefaults) {
        defaults.set(index, forKey: "screenIndex")
        if NSScreen.screens.indices.contains(index), let id = displayID(NSScreen.screens[index]) {
            defaults.set(id, forKey: "selectedDisplayID")
        }
    }

    private static func displayID(_ screen: NSScreen) -> String? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue
    }
}
