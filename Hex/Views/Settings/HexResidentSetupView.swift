import Observation
import SwiftUI

struct HexResidentSetupView: View {
  @Bindable var model: HexResidentSetupModel

  var body: some View {
    Form {
      HexResidentConfigurationFormView(model: model)

      if let statusMessage = model.statusMessage {
        HexInlineNoticeView(
          message: statusMessage,
          systemImage: "checkmark.circle.fill",
          tint: HexBrandPalette.successInk
        )
      }

      if let errorMessage = model.errorMessage {
        HexInlineNoticeView(
          message: errorMessage,
          systemImage: "exclamationmark.triangle.fill",
          tint: .orange
        )
      }

      HexResidentSetupLoadRetryView(model: model)

      HStack {
        Spacer()
        if model.isSaving {
          ProgressView()
            .controlSize(.small)
        }
        Button("Save") {
          model.save()
        }
        .buttonStyle(.hexPrimaryAction)
        .keyboardShortcut(.defaultAction)
        .disabled(!model.canSave)
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
