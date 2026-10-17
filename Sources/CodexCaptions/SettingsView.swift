import AppKit
import ApplicationServices
import CaptionCore
import CoreGraphics
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
  case general = "通用"
  case tools = "AI 工具与角色"
  case appearance = "字幕外观"
  case sounds = "任务音效"
  case interaction = "角色互动"
  case permissions = "权限"
  var id: String { rawValue }
  var icon: String {
    switch self {
    case .general: return "slider.horizontal.3"
    case .tools: return "point.3.connected.trianglepath.dotted"
    case .appearance: return "captions.bubble"
    case .sounds: return "speaker.wave.2"
    case .interaction: return "figure.wave"
    case .permissions: return "shield"
    }
  }
}

enum CuteTheme {
  static let accent = Color(red: 0.53, green: 0.8, blue: 1)
  static let line = accent.opacity(0.24)
  static let background = LinearGradient(
    colors: [
      Color(red: 0.09, green: 0.15, blue: 0.18),
      Color(red: 0.065, green: 0.11, blue: 0.14),
    ], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Complete preferences, lazily hosted separately from the compact status menu.
struct SettingsView: View {
  @ObservedObject var model: AppModel
  var isDetached = true
  var onDetach: () -> Void = {}
  var onReturnToMenu: () -> Void = {}
  var onDeveloperMode: () -> Void = {}
  var onOnboarding: () -> Void = {}
  @State private var page: SettingsPage = .appearance

  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Label("VibeCute", systemImage: "captions.bubble.fill")
          .font(.system(size: 17, weight: .semibold)).padding(.bottom, 22).padding(.horizontal, 10)
        ForEach(SettingsPage.allCases) { item in
          Button {
            page = item
          } label: {
            Label(item.rawValue, systemImage: item.icon)
              .frame(maxWidth: .infinity, alignment: .leading).padding(10)
              .foregroundStyle(page == item ? Color.white : Color.white.opacity(0.7))
              .background(
                page == item ? CuteTheme.accent.opacity(0.16) : .clear,
                in: RoundedRectangle(cornerRadius: 9))
          }.buttonStyle(.plain).accessibilityAddTraits(page == item ? .isSelected : [])
        }
        Spacer()
        #if !VIBECUTE_RELEASE
        Button("开发者模式…", action: onDeveloperMode).buttonStyle(.link).padding(10)
        #endif
      }.padding(14).frame(width: 186).background(Color.black.opacity(0.18))
      Rectangle().fill(CuteTheme.line).frame(width: 1)
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          Text(page.rawValue).font(.system(size: 21, weight: .semibold))
          pageContent
          if let error = model.errorText {
            Text(error).foregroundStyle(.orange).textSelection(.enabled)
          }
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .font(.system(size: 13)).toggleStyle(TrailingSettingsSwitchStyle()).controlSize(.small)
    .tint(CuteTheme.accent).foregroundStyle(.white).background(CuteTheme.background)
    .preferredColorScheme(.dark).frame(minWidth: 760, minHeight: 540)
  }

  @ViewBuilder private var pageContent: some View {
    switch page {
    case .general: general
    case .tools: tools
    case .appearance: appearance
    case .sounds: sounds
    case .interaction: interaction
    case .permissions: permissions
    }
  }
  private var general: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("管理字幕显示与当前跟随的任务。").foregroundStyle(.secondary)
      Toggle("显示字幕", isOn: $model.enabled)

      Text(model.status).foregroundStyle(.secondary)
      Picker("跟随", selection: $model.selection) {
        Text("自动 · 所有运行中的项目").tag("")
        ForEach(model.sessions, id: \.path) { Text($0.label).tag($0.path) }
      }.labelsHidden().disabled(model.trackedHarnesses.isEmpty)
      if model.selection.isEmpty {
        Button("锁定当前任务") { model.pinCurrent() }.buttonStyle(.link)
          .disabled(model.sessions.isEmpty)
      }

      Button("重新查看新手引导", action: onOnboarding)
      Text("VibeCute · 原生 macOS 桌面伙伴").font(.caption).foregroundStyle(.secondary)
    }
  }
  private var tools: some View {
    VStack(alignment: .leading, spacing: 14) {

      ForEach(SessionSource.allCases, id: \.preferenceID) { source in toolCard(source) }
      Text("关闭跟踪后停止读取该 Harness；角色可分别选择，也可使用同一形象。")
        .font(.system(size: 11)).foregroundStyle(.secondary)
      Divider()
      Toggle("显示不绑定 Harness 的角色", isOn: $model.companionEnabled)
      if model.companionEnabled {
        Picker(
          "独立角色",
          selection: Binding(get: { model.companionChoice }, set: { model.bindCompanion($0) })
        ) {
          ForEach(model.availableCharacters) { Text($0.title).tag($0) }
        }.pickerStyle(.menu).buttonStyle(.bordered)
      #if !VIBECUTE_RELEASE
        if model.companionChoice == .deepseekCutout {
          Picker(
            "发型",
            selection: Binding(get: { model.companionHairstyle }, set: { model.companionHair = $0 })
          ) {
            ForEach(model.cutoutHairstyles, id: \.id) { Text($0.title).tag($0.id) }
          }
        }
      #endif
      }

    }
  }
  private func toolCard(_ source: SessionSource) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Toggle(source.rawValue, isOn: HarnessSettingsBindings(model: model).tracking(source))
      HStack {
        Text(model.tracks(source) ? "正在跟踪" : "已暂停跟踪")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button(source == .doubao ? "辅助功能…" : "目录…") {
          switch source {
          case .codex: model.chooseDirectory()
          case .deepseek: model.chooseHarnessDirectory()
          case .claude: model.chooseClaudeDirectory()
          case .opencode: model.chooseOpenCodeDirectory()
          case .workbuddy: model.chooseWorkBuddyDirectory()
          case .doubao: model.openDoubaoAccessibilitySettings()
          }
        }.buttonStyle(.link).help(model.directoryPath(for: source))
      }
      Text(model.directoryPath(for: source)).font(.caption).foregroundStyle(.secondary)
        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
      Picker(
        "角色",
        selection: HarnessSettingsBindings(model: model).character(source)
      ) {
        ForEach(model.availableCharacters) { Text($0.title).tag($0) }
      }.disabled(!model.tracks(source)).pickerStyle(.menu).buttonStyle(.bordered)
      #if !VIBECUTE_RELEASE
      if model.characterChoice(for: source) == .deepseekCutout {
        Picker(
          "发型",
          selection: Binding(
            get: { model.cutoutHair(for: source) },
            set: { model.bindCutoutHair($0, to: source) })
        ) {
          ForEach(model.cutoutHairstyles, id: \.id) { Text($0.title).tag($0.id) }
        }.disabled(!model.tracks(source))
      }
      #endif
      if source == .deepseek {
        HStack {
          Text("普通余额提醒阈值（元）")
          TextField(
            "1", value: $model.balanceAlertThreshold,
            format: .number.precision(.fractionLength(0...2))
          )
          .frame(width: 80).textFieldStyle(.roundedBorder)
          .accessibilityLabel("普通余额提醒阈值（元）")
        }
        Text("悬停查询后，普通余额低于阈值时保持显示 ⚠️ 余额速度窗口；不计赠送余额。")
          .font(.caption).foregroundStyle(.secondary)
      }
      if source == .opencode {
        HStack {
          Button("安装插件") { model.installOpenCodeNavigationPlugin() }
            .disabled(!model.openCodeInstalled || model.openCodePluginInstalling)
          Text(model.openCodeNavigationStatus).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(CuteTheme.line, lineWidth: 0.8))
  }
  private var appearance: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("字幕预览随字号和底色设置实时更新。").foregroundStyle(.secondary)
      SettingsSubtitlePreview(fontSize: model.fontSize, opacity: model.opacity)
        .frame(height: 220).clipped().background(
          Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(CuteTheme.line, lineWidth: 0.8))

      settingSlider(
        "字号", value: $model.fontSize, range: 10...42, valueText: "\(Int(model.fontSize))", step: 1)
      settingSlider(
        "角色大小", value: $model.characterScale, range: 0.5...2,
        valueText: "\(Int((model.characterScale * 100).rounded()))%")
      settingSlider(
        "底色", value: $model.opacity, range: 0.15...0.95,
        valueText: "\(Int((model.opacity * 100).rounded()))%")
      if NSScreen.screens.count > 1 {
        Picker("显示器", selection: $model.screenIndex) {
          ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { index, screen in
            Text(screen.localizedName).tag(index)
          }
        }
      }
      Toggle(model.bubblesFixedToCharacter ? "允许拖动角色" : "允许拖动角色与对话框", isOn: $model.movable)
      Toggle("对话框位置固定于角色", isOn: $model.bubblesFixedToCharacter)
      Toggle("无新内容时自动隐藏", isOn: $model.autoHide)
      Toggle("字幕打字机效果", isOn: $model.typewriterEnabled)
      Text("随 token/s 自动变速；10 tps 及以下 5 字/秒，未测速时 15 字/秒。")
        .font(.system(size: 11)).foregroundStyle(.secondary)
      Toggle("同时显示最终回答", isOn: $model.showAnswers)
      Toggle("显示命令和文件编辑", isOn: $model.showTools)
      HStack {
        Button("预览提问") { model.showQuestionPreview() }.controlSize(.small)
        Button("预览审批") { model.showQuestionPreview(approval: true) }.controlSize(.small)
        if model.questionPreviewActive {
          Button("停止预览") { model.stopPreview() }.controlSize(.small)
        }
      }
      Text("演示展开、选项与审批；预览操作不会发送到真实聊天。")
        .font(.system(size: 11)).foregroundStyle(.secondary)

    }
  }
  private var sounds: some View {
    VStack(alignment: .leading, spacing: 14) {

      Toggle("提问与审批提醒", isOn: $model.questionSoundsEnabled)
      ForEach(TaskOutcome.allCases) { outcome in
        Toggle(
          "\(outcome.title)提醒",
          isOn: Binding(
            get: { model.soundEnabled(outcome) },
            set: { model.setSound(outcome, enabled: $0) }))
      }
      settingSlider(
        "音量",
        value: Binding(
          get: { model.taskSoundVolume / 3 },
          set: { model.taskSoundVolume = $0 * 3 }), range: 0...1,
        valueText: "\(Int((model.taskSoundVolume / 3 * 100).rounded()))%")
      Text("用于 Codex 提问、任务开始与结果；重复记录只提醒一次，历史任务与子任务不单独提醒。")
        .font(.system(size: 11)).foregroundStyle(.secondary)

    }
  }
  private var interaction: some View {
    VStack(alignment: .leading, spacing: 14) {

      Toggle("开启口型识别（开启可能影响系统性能）", isOn: $model.audioEnabled)
      if model.audioEnabled {
        Toggle("开启人声增强", isOn: $model.audioVoicePriority)
        settingSlider(
          "灵敏度", value: $model.audioSensitivity, range: 0.25...4,
          valueText: String(format: "%.1f×", model.audioSensitivity))
        Toggle("开启唱歌识别", isOn: $model.singingActionEnabled)
        Text(model.audioStatus).font(.system(size: 11)).foregroundStyle(.secondary)
        Button("系统录音权限…") { model.openAudioPermissions() }.buttonStyle(.link)
      }
      Toggle("蓝鱼角色自动避让复杂背景", isOn: $model.autoAvoidanceEnabled)
      if model.autoAvoidanceEnabled {
        Text(model.avoidanceStatus).font(.caption).foregroundStyle(.secondary)
        Button("立即检查背景") { model.recheckBackdrop() }
        Button("屏幕录制权限…") { model.requestBackdropPermission() }.buttonStyle(.link)
      }
      Toggle("开启蓝色大肥鱼闲置互动", isOn: $model.autoWindowPeekEnabled)

    }
  }

  private var permissions: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("仅在使用相关功能时授权；不会因打开此页而请求权限。").foregroundStyle(.secondary)
      permission(
        "辅助功能", detail: "用于读取、定位豆包窗口。其他 AI 工具字幕无需此权限。",
        status: AXIsProcessTrusted() ? "已授权" : "未授权", action: model.openDoubaoAccessibilitySettings)
      permission(
        "屏幕录制", detail: "用于角色避让复杂背景。",
        status: CGPreflightScreenCaptureAccess() ? "已授权" : "未授权",
        action: model.requestBackdropPermission)
      permission(
        "系统音频", detail: "用于口型与唱歌识别；开启识别会增加系统开销。",
        status: model.audioStatus, action: model.openAudioPermissions)
    }
  }
  private func permission(
    _ title: String, detail: String, status: String, action: @escaping () -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(title).fontWeight(.semibold)
        Spacer()
        Text(status).font(.caption).foregroundStyle(.secondary)
      }
      Text(detail).foregroundStyle(.secondary)
      Button("设置权限…", action: action)
    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).stroke(CuteTheme.line, lineWidth: 0.8))
  }
  private func settingSlider(
    _ title: String, value: Binding<Double>, range: ClosedRange<Double>, valueText: String,
    step: Double? = nil
  ) -> some View {
    HStack(spacing: 8) {
      Text(title).frame(width: 58, alignment: .leading)
      Group {
        if let step {
          Slider(value: value, in: range, step: step)
        } else {
          Slider(value: value, in: range)
        }
      }.accessibilityLabel(title)
      Text(valueText).monospacedDigit().foregroundStyle(.secondary).frame(
        width: 58, alignment: .trailing)
    }
  }
}
