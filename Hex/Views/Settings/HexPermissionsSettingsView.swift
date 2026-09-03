import Observation
import SwiftUI

struct HexPermissionsSettingsView: View {
  @Bindable var model: HexResidentSetupModel
  @Bindable var startAtLogin: HexStartAtLoginModel
  @Bindable var accessibilityPermission: HexAccessibilityPermissionModel
  let suppressAutomaticRefresh: Bool

  var body: some View {
    Form {
      HexAuthorizationModePickerView(model: model)
      HexComputerAccessView(
        accessibilityPermission: accessibilityPermission,
        startAtLogin: startAtLogin,
        suppressAutomaticRefresh: suppressAutomaticRefresh
      )

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
