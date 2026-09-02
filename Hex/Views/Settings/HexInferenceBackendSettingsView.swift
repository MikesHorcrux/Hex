import SwiftUI

struct HexInferenceBackendSettingsView: View {
  @Bindable var model: HexInferenceBackendSettingsModel

  var body: some View {
    Form {
      HexInferenceBackendFormView(model: model)

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
    .task {
      await model.load()
    }
  }
}
