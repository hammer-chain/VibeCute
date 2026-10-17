import CaptionCore
import SwiftUI

/// Both settings surfaces read/write the same model, without a draft copy.
struct HarnessSettingsBindings {
  let model: AppModel
  func tracking(_ source: SessionSource) -> Binding<Bool> {
    Binding(get: { model.tracks(source) }, set: { model.setTracking(source, enabled: $0) })
  }
  func character(_ source: SessionSource) -> Binding<CharacterChoice> {
    Binding(get: { model.characterChoice(for: source) }, set: { model.bind($0, to: source) })
  }
}
