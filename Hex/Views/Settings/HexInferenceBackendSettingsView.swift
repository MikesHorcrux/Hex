import SwiftUI

struct HexInferenceBackendSettingsView: View {
  @Bindable var model: HexInferenceBackendSettingsModel

  var body: some View {
    Form {
      HexInferenceBackendFormView(
        model: model,
        showsAdvancedConfiguration: true
      )

      HStack {
        Spacer()
        if model.isInstallingLocalModel {
          Text("Downloading…")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if model.isSaving {
          ProgressView()
            .controlSize(.small)
        }
        Button("Save") {
          model.save()
        }
        .buttonStyle(.hexPrimaryAction)
        .keyboardShortcut(.defaultAction)
        .disabled(!model.canSave)
        .accessibilityIdentifier("saveInferenceBackendSettingsButton")
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .tint(HexBrandPalette.coral)
    .task {
      await model.load()
    }
  }
}
