import HexCore
import Observation
import SwiftUI

struct HexOnboardingInferenceView: View {
  @Bindable var model: HexInferenceBackendSettingsModel

  var body: some View {
    Form {
      HexInferenceBackendFormView(
        model: model,
        showsAdvancedConfiguration: false
      )
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .tint(HexBrandPalette.coral)
    .task {
      await model.load()
    }
  }
}
