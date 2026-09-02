import Observation
import SwiftUI

struct HexPersonalitySettingsView: View {
  @Bindable var model: HexPersonalitySettingsModel

  var body: some View {
    Form {
      HexPersonalityProfileView(model: model.profile)
      HexPersonalMemoriesView(model: model.memories)
    }
    .formStyle(.grouped)
    .task {
      await model.load()
    }
  }
}
