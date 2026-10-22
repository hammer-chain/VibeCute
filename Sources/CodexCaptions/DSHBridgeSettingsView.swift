import AppKit
import SwiftUI

/// Shared by preferences and first-run setup. Checks are scoped to the visible page.
struct DSHBridgeSettingsView: View {
    @ObservedObject var bridge: DSHBridgeManager
    @State private var confirmInstallation = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("会话跳转与回复", systemImage: "arrow.up.forward.app")
                Spacer()
                if bridge.busy { ProgressView().controlSize(.small) }
                else {
                    Text(bridge.state.title).font(.caption)
                        .foregroundStyle(bridge.state == .connected ? Color.green : Color.secondary)
                        .accessibilityIdentifier("dsh-bridge-status")
                }
            }
            HStack {
                if bridge.state == .uninitialized {
                    Button("打开 DSH") { bridge.openDSH() }
                } else if bridge.state != .connected {
                    Button(bridge.state == .missing ? "启用连接…" : "修复连接…") { confirmInstallation = true }
                        .disabled(bridge.busy || bridge.state == .unchecked)
                    if bridge.state == .disconnected { Button("打开 DSH") { bridge.openDSH() } }
                }
                Button("重新检查") { bridge.refresh() }.disabled(bridge.busy)
                if let backup = bridge.lastBackup {
                    Button("查看备份") { NSWorkspace.shared.activateFileViewerSelecting([backup]) }.buttonStyle(.link)
                }
            }
        }
        .onAppear { bridge.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in bridge.refresh() }
        .alert("配置 DSH 连接？", isPresented: $confirmInstallation) {
            Button("取消", role: .cancel) {}
            Button("配置连接") { bridge.install() }
        } message: {
            Text("在 DSH 中安装本地插件，用于会话跳转、问题回复和权限审批。修改前备份配置，并保留其他插件。")
        }
    }
}
