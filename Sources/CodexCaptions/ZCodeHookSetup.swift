import CaptionCore
import Darwin
import Foundation

enum ZCodeHookSetup {
    enum Failure: LocalizedError {
        case missingResource, missingNode, unsafeConfig, changedConfig, invalidConfig
        var errorDescription: String? {
            switch self {
            case .missingResource: return "VibeCute 安装包缺少 zcode Hook。"
            case .missingNode: return "未找到可执行的 Node.js，无法安装 zcode Hook。"
            case .unsafeConfig: return "zcode 配置目录权限不安全。"
            case .changedConfig: return "zcode 配置刚被其他程序修改，请重试。"
            case .invalidConfig: return "zcode 配置格式无效，请先在 zcode 中检查。"
            }
        }
    }
    static let marker = "VibeCute request bridge"
    static var resource: URL? {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("ZCodeBridge/hook.mjs"),
           FileManager.default.fileExists(atPath: url.path) { return url }
        #if !CAPTIONS_DISTRIBUTION_BUILD
        return Bundle.module.url(forResource: "hook", withExtension: "mjs", subdirectory: "ZCodeBridge")
        #else
        return nil
        #endif
    }
    static var config: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/.zcode/cli/config.json")
    }
    static func isInstalled() -> Bool {
        guard let data = try? Data(contentsOf: config),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = object["hooks"] as? [String: Any], hooks["enabled"] as? Bool == true,
              let events = hooks["events"] as? [String: Any],
              let groups = events["PermissionRequest"] as? [[String: Any]],
              let resource else { return false }
        return groups.contains { group in
            (group["hooks"] as? [[String: Any]])?.contains { hook in
                hook["statusMessage"] as? String == marker &&
                (hook["args"] as? [String])?.contains(resource.path) == true
            } == true
        }
    }
    static func install() throws -> URL? {
        guard let resource else { throw Failure.missingResource }
        let file = config, directory = file.deletingLastPathComponent()
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { throw Failure.unsafeConfig }
        for url in [directory.deletingLastPathComponent(), directory, file] where manager.fileExists(atPath: url.path) {
            let attrs = try manager.attributesOfItem(atPath: url.path)
            guard attrs[.type] as? FileAttributeType != .typeSymbolicLink,
                  (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw Failure.unsafeConfig }
        }
        let before = manager.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
        guard (before?.count ?? 0) < 1_048_576 else { throw Failure.invalidConfig }
        var root: [String: Any] = [:]
        if let before {
            guard let decoded = try? JSONSerialization.jsonObject(with: before) as? [String: Any] else { throw Failure.invalidConfig }
            root = decoded
        }
        if root["hooks"] != nil && !(root["hooks"] is [String: Any]) { throw Failure.invalidConfig }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        if hooks["enabled"] != nil && !(hooks["enabled"] is Bool) { throw Failure.invalidConfig }
        if hooks["events"] != nil && !(hooks["events"] is [String: Any]) { throw Failure.invalidConfig }
        var events = hooks["events"] as? [String: Any] ?? [:]
        if events["PermissionRequest"] != nil && !(events["PermissionRequest"] is [[String: Any]]) { throw Failure.invalidConfig }
        var groups = events["PermissionRequest"] as? [[String: Any]] ?? []
        for index in groups.indices {
            var group = groups[index]
            if group["hooks"] != nil && !(group["hooks"] is [[String: Any]]) { throw Failure.invalidConfig }
            var entries = group["hooks"] as? [[String: Any]] ?? []
            entries.removeAll { $0["statusMessage"] as? String == marker }
            group["hooks"] = entries; groups[index] = group
        }
        groups.removeAll { ($0["hooks"] as? [[String: Any]])?.isEmpty == true }
        let nodeCandidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        guard let node = nodeCandidates.first(where: { access($0, X_OK) == 0 }) else { throw Failure.missingNode }
        groups.append(["matcher": "*", "hooks": [["type": "process", "command": node,
            "args": [resource.path], "timeoutMs": 300_000, "statusMessage": marker]]])
        events["PermissionRequest"] = groups
        hooks["enabled"] = true; hooks["events"] = events; root["hooks"] = hooks
        let updated = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        if updated == before { return nil }
        guard (try? Data(contentsOf: file)) == before else { throw Failure.changedConfig }
        var backup: URL?
        if let before {
            let url = directory.appendingPathComponent("config.json.vibecute-\(UUID().uuidString).bak")
            try before.write(to: url, options: .withoutOverwriting)
            _ = chmod(url.path, 0o600); backup = url
        }
        let temporary = directory.appendingPathComponent(".vibecute-config-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw Failure.unsafeConfig }
        defer { _ = unlink(temporary.path) }
        let count = updated.withUnsafeBytes { write(fd, $0.baseAddress!, updated.count) }
        _ = fsync(fd); close(fd)
        guard count == updated.count else { throw Failure.unsafeConfig }
        guard (try? Data(contentsOf: file)) == before else { throw Failure.changedConfig }
        guard rename(temporary.path, file.path) == 0 else { throw Failure.unsafeConfig }
        return backup
    }
}
