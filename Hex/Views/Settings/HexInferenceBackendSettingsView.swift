import HexCore
import SwiftUI

struct HexInferenceBackendSettingsView: View {
  @Bindable var model: HexInferenceBackendSettingsModel

  var body: some View {
    Form {
      Section {
        Picker("Backend", selection: $model.selectedBackend) {
          ForEach(HexInferenceBackendKind.allCases) { backend in
            VStack(alignment: .leading) {
              Text(backend.displayName)
              Text(backend.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .tag(backend)
          }
        }
        .accessibilityIdentifier("inferenceBackendPicker")
      } header: {
        Text("Inference backend")
      } footer: {
        Text("Hex stores this selection and other non-secret setup in its protected settings file.")
      }

      switch model.selectedBackend {
      case .openAIResponses:
        HexOpenAIBackendSettingsView(model: model)
      case .mlxLocal:
        HexMLXBackendSettingsView(model: model)
      case .codexCompatibility:
        HexCodexCompatibilitySettingsView(model: model)
      }

      if let statusMessage = model.statusMessage {
        Text(statusMessage)
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      if let errorMessage = model.errorMessage {
        Text(errorMessage)
          .font(.callout)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack {
        Spacer()
        if model.isSaving {
          ProgressView()
            .controlSize(.small)
        }
        Button("Save") {
          model.save()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!model.canSave)
        .accessibilityIdentifier("saveInferenceBackendSettingsButton")
      }
    }
    .formStyle(.grouped)
    .frame(width: 560)
    .scenePadding()
    .task {
      await model.load()
    }
  }
}
