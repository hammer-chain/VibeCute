import AppKit

/// zcode does not expose a reliable route to an individual conversation.
/// Activating its desktop app leaves the current conversation untouched.
enum ZCodeConversationNavigator {
    private static let bundleID = "dev.zcode.app"

    static func open() -> String? {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           running.activate(options: [.activateAllWindows]) {
            return nil
        }
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return "无法打开 zcode，请确认已安装桌面应用。"
        }
        return NSWorkspace.shared.open(application) ? nil : "无法打开 zcode。"
    }
}
