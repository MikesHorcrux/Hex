import Observation
import SwiftUI

struct HexOnboardingPersonalityView: View {
  @Bindable var model: HexPersonalitySettingsModel

  var body: some View {
    Form {
      Section {
        HexInlineNoticeView(
          message:
            "This is optional. Anything you add stays local, remains visible, and can be changed later.",
          systemImage: "sparkles",
          tint: HexBrandPalette.coral
        )
      }
      HexPersonalityProfileView(model: model.profile, showsSaveAction: false)
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .tint(HexBrandPalette.coral)
    .task {
      await model.profile.load()
    }
  }
}
