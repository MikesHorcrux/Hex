import Observation
import SwiftUI

struct HexToolsSettingsView: View {
  @Bindable var model: HexResidentSetupModel

  var body: some View {
    Form {
      HexMCPIntegrationsView(model: model)
      HexHTTPMCPServersView(model: model)

      if let statusMessage = model.statusMessage {
        Text(statusMessage)
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      if let errorMessage = model.errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .font(.callout)
          .foregroundStyle(.orange)
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
      }
    }
    .formStyle(.grouped)
    .task {
      await model.load()
    }
  }
}
