import SwiftUI

/// Keep native switches, with a shared trailing edge across every settings row.
struct TrailingSettingsSwitchStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 12) {
      configuration.label
      Spacer(minLength: 12)
      Toggle(isOn: configuration.$isOn) { configuration.label }
        .labelsHidden().toggleStyle(.switch).fixedSize()
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
