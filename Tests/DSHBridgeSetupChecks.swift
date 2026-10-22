import AppKit
import SwiftUI
import CaptionCore
@testable import CodexCaptions

@main struct DSHBridgeSetupChecks {
    static func main() throws {
        func require(_ value: @autoclosure () throws -> Bool) rethrows { let passed = try value(); precondition(passed) }
        let fm=FileManager.default
        let root=fm.temporaryDirectory.appendingPathComponent("vibecute-dsh-setup-"+UUID().uuidString)
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:root) }
        let payload=try DSHBridgeSetup.payload(at:DSHBridgeSetup.resources)
        try require(try DSHBridgeSetup.replacingBlock(in:"# empty profile\n[]\n",with:payload.block)
            == "# empty profile\n"+payload.block+"\n")
        let profile=root.appendingPathComponent("profiles/desktop")
        try fm.createDirectory(at:profile,withIntermediateDirectories:true)
        let patch=profile.appendingPathComponent("cordis.patch.yml")
        let original="# 保留现有插件\n- id: existing-tool\n  config:\n    enabled: true\n"
        try Data(original.utf8).write(to:patch)
        let backup=try DSHBridgeSetup.install(home:root,resources:DSHBridgeSetup.resources)!
        try require(try String(contentsOf:backup,encoding:.utf8) == original)
        try require(try String(contentsOf:patch,encoding:.utf8).hasPrefix(original))
        try require(try DSHBridgeSetup.matches(home:root,payload:payload))
        try require(try DSHBridgeSetup.install(home:root,resources:DSHBridgeSetup.resources) == nil)
        let backupMode=try fm.attributesOfItem(atPath:backup.path)[.posixPermissions] as! NSNumber
        precondition(backupMode.intValue == 0o600)
        // Another tool rewrites config: repair the bridge without restoring stale plugin settings.
        let changed=original.replacingOccurrences(of:"enabled: true",with:"enabled: false")
        try Data(changed.utf8).write(to:patch)
        try require(!(try DSHBridgeSetup.matches(home:root,payload:payload)))
        let repairBackup=try DSHBridgeSetup.install(home:root,resources:DSHBridgeSetup.resources)!
        try require(try String(contentsOf:repairBackup,encoding:.utf8) == changed)
        try require(try String(contentsOf:patch,encoding:.utf8).hasPrefix(changed))
        let module=profile.appendingPathComponent("node_modules/"+payload.package+"/client.js")
        try Data("outdated".utf8).write(to:module)
        try require(!(try DSHBridgeSetup.matches(home:root,payload:payload)))
        _=try DSHBridgeSetup.install(home:root,resources:DSHBridgeSetup.resources)
        try require(try DSHBridgeSetup.matches(home:root,payload:payload))
        let saved=try Data(contentsOf:patch)
        try fm.removeItem(at:module)
        let outside=root.appendingPathComponent("unrelated.js")
        try Data("do not change".utf8).write(to:outside)
        try fm.createSymbolicLink(at:module,withDestinationURL:outside)
        do { _=try DSHBridgeSetup.install(home:root,resources:DSHBridgeSetup.resources); fatalError("symlink accepted") }
        catch DSHBridgeSetup.Failure.unsafePath {}
        try require(try Data(contentsOf:patch) == saved)
        try require(try String(contentsOf:outside,encoding:.utf8) == "do not change")
        do { _=try DSHBridgeSetup.replacingBlock(in:original+DSHBridgeSetup.begin,with:payload.block);fatalError("incomplete marker accepted") }
        catch DSHBridgeSetup.Failure.malformed {}
        do { _=try DSHBridgeSetup.replacingBlock(in:"plugins: {}\n",with:payload.block);fatalError("mapping root accepted") }
        catch DSHBridgeSetup.Failure.malformed {}
        let empty=root.appendingPathComponent("no-profile")
        do { _=try DSHBridgeSetup.install(home:empty,resources:DSHBridgeSetup.resources);fatalError("uninitialized profile accepted") }
        catch DSHBridgeSetup.Failure.uninitialized {}
        precondition(!fm.fileExists(atPath:empty.path))
        let tooLarge=root.appendingPathComponent("large")
        try Data(repeating:65,count:1_048_577).write(to:tooLarge)
        do { _=try DSHBridgeSetup.read(tooLarge);fatalError("unbounded read") }
        catch DSHBridgeSetup.Failure.tooLarge {}
        print("PASS: bundled payload, first install without sessions, exact backups, unchanged other settings, idempotence, missing-config repair, outdated assets, symlink and malformed-config refusal, bounded reads")
        if CommandLine.arguments.contains("--ui") {
            let app=NSApplication.shared; app.setActivationPolicy(.regular); app.finishLaunching()
            let bridge=DSHBridgeManager()
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:520,height:150),
                styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.title="DSH 连接验收"; window.isReleasedWhenClosed=false
            window.contentViewController=NSHostingController(rootView:
                DSHBridgeSettingsView(bridge:bridge).padding(24).frame(width:520,height:150)
                    .background(Color(red:0.09,green:0.15,blue:0.18)).foregroundStyle(.white).preferredColorScheme(.dark))
            window.center();window.makeKeyAndOrderFront(nil);app.activate(ignoringOtherApps:true)
            app.run()
        }
        if CommandLine.arguments.contains("--onboarding") {
            let freshHome=root.appendingPathComponent("first-run-home")
            let freshProfile=freshHome.appendingPathComponent("profiles/desktop")
            try fm.createDirectory(at:freshProfile,withIntermediateDirectories:true)
            try Data("# fresh DSH profile\n".utf8).write(to:freshProfile.appendingPathComponent("cordis.patch.yml"))
            let previous=getenv("DSH_HOME").map { String(cString:$0) }
            setenv("DSH_HOME",freshHome.path,1)
            defer { if let previous { setenv("DSH_HOME",previous,1) } else { unsetenv("DSH_HOME") } }
            let app=NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
            precondition(!NSScreen.screens.isEmpty)
            let model=AppModel()
            let flow=OnboardingController(model:model)
            flow.showConnection()
            let deadline=Date().addingTimeInterval(5)
            while flow.checkingConnections && Date()<deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.05)) }
            precondition(flow.availableConnectionSources.contains(.deepseek),"DSH is offered before any session exists")
            precondition(model.sessions.isEmpty,"Do not borrow real sessions for this first-run fixture")
            RunLoop.main.run(until:Date().addingTimeInterval(0.3))
            let window=app.windows.first { $0.title == "连接 AI 工具" }!
            let view=window.contentView!
            let rep=view.bitmapImageRepForCachingDisplay(in:view.bounds)!
            view.cacheDisplay(in:view.bounds,to:rep)
            let output=URL(fileURLWithPath:"output/dsh-setup/first-run.png")
            try fm.createDirectory(at:output.deletingLastPathComponent(),withIntermediateDirectories:true)
            try rep.representation(using:.png,properties:[:])!.write(to:output)
            flow.cancelConnection()
            print("PASS: real first-run connection window offers DSH with an initialized profile and zero session logs; fixture profile unchanged")
        }
    }
}
