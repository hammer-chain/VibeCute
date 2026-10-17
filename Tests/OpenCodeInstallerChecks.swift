import Foundation
@main enum OpenCodeInstallerChecks {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        precondition(OpenCodeNavigationInstaller.installedExecutable(directories: [directory.path]) == nil)
        let command = directory.appendingPathComponent("opencode")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: command)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: command.path)
        precondition(OpenCodeNavigationInstaller.installedExecutable(directories: [directory.path]) == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
        precondition(OpenCodeNavigationInstaller.installedExecutable(directories: [directory.path]) == command)
        let config = directory.appendingPathComponent("config")
        let installer = OpenCodeNavigationInstaller()
        precondition(!config.path.isEmpty && !FileManager.default.fileExists(atPath: config.path))
        if CommandLine.arguments.count > 1 {
            let resources = URL(fileURLWithPath: CommandLine.arguments[1])
            func install() {
                installer.install(resources: resources, configDirectory: config)
                let end = Date().addingTimeInterval(5)
                while installer.isInstalling && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
                precondition(!installer.isInstalling && installer.status.contains("已"), installer.status)
            }
            install()
            let plugin = config.appendingPathComponent("captions-navigation.mjs")
            let before = try FileManager.default.attributesOfItem(atPath: plugin.path)[.modificationDate] as! Date
            install()
            precondition(installer.status == "OpenCode 导航插件已就绪")
            let after = try FileManager.default.attributesOfItem(atPath: plugin.path)[.modificationDate] as! Date
            precondition(after == before)
        }
        print("PASS installed executable detection, non-executable rejection, no install on construction, explicit install and repeat no writes")
    }
}
