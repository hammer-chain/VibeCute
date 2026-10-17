import Foundation

/// User-triggered, asynchronous, idempotent installation of the bundled plugin.
final class OpenCodeNavigationInstaller {
    private var process: Process?
    private var timeout: DispatchWorkItem?
    var onStatus: ((String) -> Void)?
    private(set) var status = "等待检测 OpenCode" { didSet { onStatus?(status) } }
    var isInstalling: Bool { process != nil }
    static func installedExecutable(directories: [String]? = nil) -> URL? {
        let home = NSHomeDirectory()
        let defaults = ["/opt/homebrew/bin", "/usr/local/bin", home + "/.opencode/bin", home + "/.local/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").prefix(64).map(String.init)
        var seen = Set<String>()
        for directory in directories ?? defaults where seen.insert(directory).inserted {
            let file = URL(fileURLWithPath: directory).appendingPathComponent("opencode")
            var isDirectory = ObjCBool(false)
            if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue,
               FileManager.default.isExecutableFile(atPath: file.path) { return file }
        }
        return nil
    }
    func install(resources: URL? = Bundle.main.resourceURL, configDirectory: URL? = nil) {
        guard process == nil else { return }
        guard let executable = Self.installedExecutable() else { status = "未检测到 OpenCode，已跳过安装"; return }
        guard let resources else { status = "缺少 OpenCode 导航插件资源"; return }
        let script = resources.appendingPathComponent("OpenCodeNavigation/install.sh")
        guard FileManager.default.fileExists(atPath: script.path) else { status = "缺少 OpenCode 导航安装脚本"; return }
        let child = Process(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: "/bin/sh"); child.arguments = [script.path, configDirectory?.path ??
            ((ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? NSHomeDirectory() + "/.config") + "/opencode"), executable.path]
        child.standardOutput = output; child.standardError = output
        process = child; status = "正在安装 OpenCode 导航插件"
        child.terminationHandler = { [weak self] task in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            DispatchQueue.main.async {
                guard let self else { return }
                self.timeout?.cancel(); self.timeout = nil; self.process = nil
                if task.terminationStatus == 0,
                   let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if result["status"] as? String == "skipped" { self.status = "未检测到 OpenCode，已跳过安装"; return }
                    self.status = result["status"] as? String == "up-to-date" ? "OpenCode 导航插件已就绪" : "OpenCode 导航插件已安装，重新打开 OpenCode 后生效"
                } else { self.status = "OpenCode 导航插件安装失败，请检查配置格式和目录权限" }
            }
        }
        do { try child.run() } catch { process = nil; status = "无法启动 OpenCode 导航安装脚本"; return }
        let timeout = DispatchWorkItem { [weak child] in if let child, child.isRunning { child.terminate() } }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    }
}
