import CaptionCore
import SwiftUI

struct MenuPanelView: View {
  @ObservedObject var model: AppModel
  var maximumHeight: CGFloat = 720
  @State private var contentHeight: CGFloat = 0
  var onHeightChange: (CGFloat) -> Void = { _ in }
  var onPreferences: () -> Void
  var onOnboarding: () -> Void
  private var bindings: HarnessSettingsBindings { HarnessSettingsBindings(model: model) }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 10) {
          Image(systemName: "captions.bubble.fill").font(.system(size: 25)).foregroundStyle(
            CuteTheme.accent)
          VStack(alignment: .leading, spacing: 4) {
            Text("VibeCute").font(.system(size: 17, weight: .semibold))
            Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
          }
          Spacer()
        }
        divider
        Toggle("显示字幕", isOn: $model.enabled)
        divider
        Toggle("任务音效", isOn: $model.taskSoundsEnabled)
          .accessibilityIdentifier("menu-task-sound")
        volumeSlider("任务音量", value: Binding(
          get: { model.taskSoundVolume / 3 }, set: { model.taskSoundVolume = $0 * 3 }),
          enabled: model.taskSoundsEnabled, id: "menu-task-volume")
        Toggle("天气音效", isOn: $model.desktopRainSound)
          .accessibilityIdentifier("menu-weather-sound")
        volumeSlider("远处雨声", value: $model.desktopRainVolume,
          enabled: model.desktopRainSound, id: "menu-weather-volume")
        volumeSlider("近处雨滴", value: $model.desktopRainDropsVolume,
          enabled: model.desktopRainSound, id: "menu-rain-drops-volume")
        Text(model.rainAudioMappingLabel).font(.caption2).foregroundStyle(.secondary)
        volumeSlider("雷声", value: $model.desktopRainThunderVolume,
          enabled: model.desktopRainSound, id: "menu-thunder-volume")
        volumeSlider("钢盆敲击声", value: $model.desktopRainBasinVolume,
          enabled: model.desktopRainSound, id: "menu-basin-volume")
        divider
        Text("Harness 与角色").fontWeight(.semibold)
        VStack(alignment: .leading, spacing: 10) {
          ForEach(SessionSource.allCases, id: \.preferenceID) { source in
            VStack(alignment: .leading, spacing: 5) {
              Toggle(source.rawValue, isOn: bindings.tracking(source))
                .accessibilityIdentifier("menu-tracking-" + source.preferenceID)
              Picker("角色", selection: bindings.character(source)) {
                ForEach(model.availableCharacters) { Text($0.title).tag($0) }
              }.pickerStyle(.menu).buttonStyle(.bordered)
                .disabled(!model.tracks(source))
                .accessibilityLabel(source.rawValue + "角色")
                .accessibilityIdentifier("menu-character-" + source.preferenceID)
            }
          }
        }
        divider
        Toggle("显示独立角色", isOn: $model.companionEnabled)
          .help("控制不绑定 AI 工具的角色；各工具角色在偏好设置中管理")
        if model.companionEnabled {
          Picker(
            "独立角色",
            selection: Binding(get: { model.companionChoice }, set: { model.bindCompanion($0) })
          ) {
            ForEach(model.availableCharacters) { Text($0.title).tag($0) }
          }.pickerStyle(.menu).buttonStyle(.bordered)
        }
        divider
        Button(action: onPreferences) {
          HStack {
            Text("偏好设置…")
            Spacer()
            Text("⌘,").foregroundStyle(.secondary)
          }
        }
        .buttonStyle(.plain).keyboardShortcut(",", modifiers: .command)
        Button("重新查看新手引导", action: onOnboarding).buttonStyle(.plain)
        HStack {
          Spacer()
          Button("退出 VibeCute") { NSApp.terminate(nil) }.buttonStyle(.plain).foregroundStyle(
            .secondary)
        }
      }.padding(18).frame(width: 340).font(.system(size: 13))
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { geometry in
          Color.clear.preference(key: MenuContentHeight.self, value: geometry.size.height)
        })
    }.frame(width: 340, height: min(maximumHeight, contentHeight > 0 ? contentHeight : maximumHeight))
      .scrollDisabled(contentHeight <= maximumHeight)
      .onPreferenceChange(MenuContentHeight.self) { height in
        guard height > 0 else { return }
        if abs(contentHeight - height) > 0.5 { contentHeight = height }
        onHeightChange(min(maximumHeight, height))
      }
      .onChange(of: maximumHeight) { height in
        onHeightChange(min(height, contentHeight > 0 ? contentHeight : height))
      }
      .toggleStyle(TrailingSettingsSwitchStyle()).controlSize(.small)
      .foregroundStyle(.white).tint(CuteTheme.accent).background(CuteTheme.background)
      .preferredColorScheme(.dark)
  }
  private var divider: some View { Rectangle().fill(CuteTheme.line).frame(height: 0.8) }
  private func volumeSlider(_ title: String, value: Binding<Double>, enabled: Bool, id: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text(title).foregroundStyle(.secondary)
        Spacer()
        Text("\(Int((value.wrappedValue * 100).rounded()))%")
          .monospacedDigit().foregroundStyle(.secondary)
      }.font(.caption)
      Slider(value: value, in: 0...1).accessibilityLabel(title).accessibilityIdentifier(id)
    }.disabled(!enabled)
  }
}

private struct MenuContentHeight: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
