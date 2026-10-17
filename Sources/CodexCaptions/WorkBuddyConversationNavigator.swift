import AppKit

enum WorkBuddyConversationNavigator {
    static func open(sessionID: String) -> String? {
        var link = URLComponents()
        link.scheme = "workbuddy"; link.host = "chat"; link.path = "/" + sessionID
        if !sessionID.isEmpty, let url = link.url, NSWorkspace.shared.open(url) { return nil }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.tencent.workbuddy.mac"),
              NSWorkspace.shared.open(app) else {
            return "无法打开 WorkBuddy，请确认已安装桌面应用。"
        }
        return nil
    }
}
