import HexCore
import Observation
import SwiftUI

struct HexOnboardingInferenceView: View {
  @Bindable var model: HexInferenceBackendSettingsModel

  var body: some View {
    Form {
      Section {
        Text("Choose the model engine. Hex—not the provider SDK—owns the agent loop and tools.")
          .foregroundStyle(.secondary)
      }
      HexInferenceBackendFormView(model: model, includesCodexCompatibility: false)
    }
    .formStyle(.grouped)
    .task {
      await model.load()
      if model.selectedBackend == .codexCompatibility {
        model.selectedBackend = .openAIResponses
      }
    }
  }
}
