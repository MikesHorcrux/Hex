import Observation
import SwiftUI

struct HexOnboardingPersonalityView: View {
  @Bindable var model: HexPersonalitySettingsModel

  var body: some View {
    Form {
      Section {
        Text("Make Hex feel like your agent. This profile is local, explicit, and always editable.")
          .foregroundStyle(.secondary)
      }
      HexPersonalityProfileView(model: model.profile)
    }
    .formStyle(.grouped)
    .task {
      await model.profile.load()
    }
  }
}
