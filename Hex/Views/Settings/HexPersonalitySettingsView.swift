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
    .frame(width: 650, height: 760)
    .scenePadding()
    .task {
      await model.load()
    }
  }
}
