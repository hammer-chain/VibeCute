import AppKit
import Combine
import CryptoKit
import Foundation

enum DSHBridgePaths {
    static var home: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["DSH_HOME"] ?? NSHomeDirectory() + "/.dsh",
            isDirectory: true).standardizedFileURL
    }
    static var socket: String { home.appendingPathComponent("vibecute/approval.sock").path }
}

/// Bundled JavaScript runs inside DSH. Setup itself uses only native file APIs.
/// Both first-time setup and repairs preserve all configuration outside our marked block.
enum DSHBridgeSetup {
    static let files = ["index.mjs", "client.js", "package.json"]
    static let begin = "# BEGIN VibeCute approval bridge"
    static let end = "# END VibeCute approval bridge"
    enum Failure: LocalizedError {
        case uninitialized, resources, unsafePath, changed, malformed, tooLarge
        var errorDescription: String? {
            switch self {
            case .uninitialized: return "请先打开 DSH，完成首次设置。"
            case .resources: return "安装资源不完整，请重新安装 VibeCute。"
            case .unsafePath: return "DSH 配置路径不可安全写入，请检查目录权限。"
            case .changed: return "DSH 配置正在变化，请稍后重试。"
            case .malformed: return "VibeCute 配置标记不完整，请先检查 DSH 配置。"
            case .tooLarge: return "DSH 配置超出读取上限，请检查配置文件。"
            }
        }
    }
    struct Payload {
        let contents: [String: Data]
        let package: String
        let revision: String
        var block: String {
            "\(begin)\n- insert:\n    - id: \(package.split(separator: "/").last!)\n      name: \"\(package)\"\n      config:\n        revision: \"\(revision)\"\n\(end)"
        }
    }
    static var resources: URL? {
        let folder = Bundle.main.resourceURL?.appendingPathComponent("DSHBridge")
        if let folder, FileManager.default.fileExists(atPath: folder.appendingPathComponent("package.json").path) { return folder }
        #if !CAPTIONS_DISTRIBUTION_BUILD
        return Bundle.module.url(forResource: "DSHBridge", withExtension: nil)
        #else
        return nil
        #endif
    }
    static func read(_ url: URL, maximum: Int = 1_048_576) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw Failure.tooLarge }
        return data
    }
    static func payload(at resources: URL?) throws -> Payload {
        guard let resources else { throw Failure.resources }
        var contents: [String: Data] = [:], hash = SHA256()
        for name in files {
            let bytes = try read(resources.appendingPathComponent(name))
            contents[name] = bytes; hash.update(data: bytes)
        }
        guard let info = try JSONSerialization.jsonObject(with: contents["package.json"]!) as? [String: Any],
              let package = info["name"] as? String,
              package.range(of: "^@local/vibecute-approval-bridge-v[0-9]+$", options: .regularExpression) != nil else { throw Failure.resources }
        return Payload(contents: contents, package: package,
            revision: hash.finalize().map { String(format: "%02x", $0) }.joined().prefix(16).description)
    }
    static func replacingBlock(in original: String, with block: String) throws -> String {
        let content = original.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        if content == ["[]"] {
            return original.replacingOccurrences(of: "(?m)^[ \\t]*\\[\\][ \\t]*$", with: block, options: .regularExpression)
        }
        guard content.first.map({ $0.hasPrefix("- ") || $0 == "-" }) ?? true else { throw Failure.malformed }
        let starts = original.components(separatedBy: begin).count - 1
        let ends = original.components(separatedBy: end).count - 1
        if starts == 0 && ends == 0 {
            guard !original.contains("vibecute-approval-bridge") else { throw Failure.malformed }
            return original + (original.hasSuffix("\n") || original.isEmpty ? "" : "\n") + "\n" + block + "\n"
        }
        guard starts == 1, ends == 1, let start = original.range(of: begin),
              let stop = original.range(of: end), start.lowerBound < stop.lowerBound else { throw Failure.malformed }
        return String(original[..<start.lowerBound]) + block + String(original[stop.upperBound...])
    }
    static func assertSafe(_ url: URL) throws {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return }
        guard attributes[.type] as? FileAttributeType != .typeSymbolicLink,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw Failure.unsafePath }
    }
    /// Returns a backup only when config changes. A second identical install is a no-op.
    static func install(home: URL, resources: URL?) throws -> URL? {
        let manager = FileManager.default, payload = try payload(at: resources)
        let profile = home.appendingPathComponent("profiles/desktop", isDirectory: true)
        let patch = profile.appendingPathComponent("cordis.patch.yml")
        guard manager.fileExists(atPath: patch.path) else { throw Failure.uninitialized }
        for url in [home, home.appendingPathComponent("profiles"), profile, patch] { try assertSafe(url) }
        let before = try read(patch)
        guard let original = String(data: before, encoding: .utf8) else { throw Failure.malformed }
        let updated = Data(try replacingBlock(in: original, with: payload.block).utf8)
        var folder = profile
        for component in ["node_modules", "@local", String(payload.package.split(separator: "/").last!)] {
            folder.appendPathComponent(component, isDirectory: true); try assertSafe(folder)
            var isDirectory = ObjCBool(false)
            if manager.fileExists(atPath: folder.path, isDirectory: &isDirectory) {
                guard isDirectory.boolValue else { throw Failure.unsafePath }
            } else { try manager.createDirectory(at: folder, withIntermediateDirectories: false) }
        }
        for name in files {
            let destination = folder.appendingPathComponent(name); try assertSafe(destination)
            if (try? read(destination)) != payload.contents[name] {
                try payload.contents[name]!.write(to: destination, options: .atomic)
            }
        }
        guard before != updated else { return nil }
        guard try read(patch) == before else { throw Failure.changed }
        let backup = profile.appendingPathComponent("cordis.patch.yml.vibecute-\(UUID().uuidString).bak")
        try manager.copyItem(at: patch, to: backup)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        let temporary = profile.appendingPathComponent(".vibecute-\(UUID().uuidString).tmp")
        defer { try? manager.removeItem(at: temporary) }
        try updated.write(to: temporary, options: .withoutOverwriting)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        // Recheck immediately before the atomic rename, including edits by other DSH tools.
        guard try read(patch) == before else { throw Failure.changed }
        guard rename(temporary.path, patch.path) == 0 else { throw Failure.unsafePath }
        return backup
    }
    static func matches(home: URL, payload: Payload) throws -> Bool {
        let profile = home.appendingPathComponent("profiles/desktop")
        let bytes = try read(profile.appendingPathComponent("cordis.patch.yml"))
        guard let original = String(data: bytes, encoding: .utf8), original.contains(payload.block),
              try replacingBlock(in: original, with: payload.block) == original else { return false }
        let folder = profile.appendingPathComponent("node_modules/" + payload.package)
        return files.allSatisfy { (try? read(folder.appendingPathComponent($0))) == payload.contents[$0] }
    }
}

final class DSHBridgeManager: ObservableObject {
    enum State: Equatable {
        case unchecked, checking, uninitialized, missing, repair, disconnected, connected, installing, failed(String)
        var title: String {
            switch self {
            case .unchecked: return "尚未检查"
            case .checking: return "正在检查…"
            case .uninitialized: return "请先打开 DSH 完成首次设置"
            case .missing: return "尚未启用"
            case .repair: return "连接配置需要修复"
            case .disconnected: return "已配置，等待 DSH 连接"
            case .connected: return "已连接"
            case .installing: return "正在配置…"
            case let .failed(message): return message
            }
        }
    }
    @Published private(set) var state: State = .unchecked
    @Published private(set) var lastBackup: URL?
    let home: URL
    private let resources: URL?
    private let queue = DispatchQueue(label: "captions.dsh.setup", qos: .utility)
    var busy: Bool { state == .checking || state == .installing }
    var detected: Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent("profiles/desktop").path)
            || NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.deepseek.dsh") != nil
    }
    init(home: URL = DSHBridgePaths.home, resources: URL? = DSHBridgeSetup.resources) {
        self.home = home; self.resources = resources
    }
    func refresh() {
        guard !busy else { return }; state = .checking
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.check()
            DispatchQueue.main.async { self.state = result }
        }
    }
    func install() {
        guard !busy else { return }; state = .installing
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let backup = try DSHBridgeSetup.install(home: self.home, resources: self.resources)
                // A single deferred read allows DSH's existing config watcher to reload.
                self.queue.asyncAfter(deadline: .now() + 1) {
                    let result = self.check()
                    DispatchQueue.main.async { self.lastBackup = backup ?? self.lastBackup; self.state = result }
                }
            } catch { DispatchQueue.main.async { self.state = .failed(error.localizedDescription) } }
        }
    }
    private func check() -> State {
        let patch = home.appendingPathComponent("profiles/desktop/cordis.patch.yml")
        guard FileManager.default.fileExists(atPath: patch.path) else { return .uninitialized }
        do {
            let payload = try DSHBridgeSetup.payload(at: resources)
            guard try DSHBridgeSetup.matches(home: home, payload: payload) else {
                let bytes = try DSHBridgeSetup.read(patch)
                let installed = FileManager.default.fileExists(atPath:
                    home.appendingPathComponent("profiles/desktop/node_modules/" + payload.package).path)
                return installed || String(decoding: bytes, as: UTF8.self).contains("vibecute-approval-bridge") ? .repair : .missing
            }
            do {
                let connection = try CodexQuestionConnection(path: home.appendingPathComponent("vibecute/approval.sock").path)
                connection.deadline = ProcessInfo.processInfo.systemUptime + 4
                let reply = try connection.bridgeExchange(["version": 1, "operation": "bridge-status"])
                return reply["status"] as? String == "ok" && reply["revision"] as? String == payload.revision
                    && reply["clientVersion"] as? String == "v11" ? .connected : .disconnected
            } catch { return .disconnected }
        } catch { return .failed(error.localizedDescription) }
    }
    func openDSH() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.deepseek.dsh") {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        } else { state = .failed("未找到 DSH，请先安装 DSH。") }
    }
}
