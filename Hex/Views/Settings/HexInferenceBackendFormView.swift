import HexCore
import Observation
import SwiftUI

struct HexInferenceBackendFormView: View {
  @Bindable var model: HexInferenceBackendSettingsModel

  var body: some View {
    Section {
      Picker("Backend", selection: $model.selectedBackend) {
        ForEach(HexInferenceBackendKind.allCases) { backend in
          Text(backend.displayName)
            .tag(backend)
        }
      }
      .accessibilityIdentifier("inferenceBackendPicker")
    } header: {
      Text("Inference backend")
    } footer: {
      Text("Choose where the model runs. Hex remains the agent runtime in every mode.")
    }

    switch model.selectedBackend {
    case .openAIResponses:
      HexOpenAIBackendSettingsView(model: model)
    case .mlxLocal:
      HexMLXBackendSettingsView(model: model)
    }

    if let statusMessage = model.statusMessage {
      Text(statusMessage)
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    if let errorMessage = model.errorMessage {
      Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
        .font(.callout)
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

}
