import AppKit
import ApplicationServices

enum DoubaoConversationNavigator {
    static func open(sessionID: String) -> String? {
        let workspace = NSWorkspace.shared
        guard let appURL = workspace.urlForApplication(withBundleIdentifier: "com.work.pc.doubao") else {
            return "无法打开豆包工作，请确认已安装桌面应用。"
        }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.work.pc.doubao").first,
           AXIsProcessTrusted(), !sessionID.isEmpty, sessionID.utf8.count <= 64,
           sessionID.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) {
            running.activate(options: [.activateAllWindows])
            let app = AXUIElementCreateApplication(running.processIdentifier)
            AXUIElementSetMessagingTimeout(app, 0.04)
            let target = "chrome://doubaowork-chat/chat/" + sessionID
            let deadline = ProcessInfo.processInfo.systemUptime + 0.3
            var queue = ((attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []).map { ($0, $0) }
            var index = 0
            // The reader follows an already-open chat. Raise its exact window;
            // switching unopened chats is not supported by the installed client.
            while index < queue.count && index < 384 && ProcessInfo.processInfo.systemUptime < deadline {
                let (element, window) = queue[index]; index += 1
                let url = attribute(element, kAXURLAttribute)
                let location = (url as? URL)?.absoluteString ?? (url as? String) ?? ""
                if location == target {
                    let role = attribute(element, kAXRoleAttribute) as? String
                    if role == "AXWebArea" {
                        _ = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                        running.activate(options: [.activateAllWindows])
                        return nil
                    }
                }
                let remaining = 384 - queue.count
                if remaining > 0, ProcessInfo.processInfo.systemUptime < deadline {
                    var children: CFArray?
                    if AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0,
                        min(remaining, 64), &children) == .success, let children = children as? [AXUIElement] {
                        queue.append(contentsOf: children.map { ($0, window) })
                    }
                }
            }
        }
        return workspace.open(appURL) ? nil : "无法打开豆包工作窗口。"
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
