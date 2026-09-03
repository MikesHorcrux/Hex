import Observation
import SwiftUI

struct HexOnboardingPermissionsView: View {
  @Bindable var model: HexResidentSetupModel
  @Bindable var startAtLogin: HexStartAtLoginModel
  @Bindable var accessibilityPermission: HexAccessibilityPermissionModel

  var body: some View {
    Form {
      Section {
        Text(
          "Hex approvals and macOS permissions are separate. You choose Hex's policy; macOS remains the final authority for protected system access."
        )
        .foregroundStyle(.secondary)
      }
      HexAuthorizationModePickerView(model: model)
      HexComputerAccessView(
        accessibilityPermission: accessibilityPermission,
        startAtLogin: startAtLogin
      )

      if let errorMessage = model.errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
      }
    }
    .formStyle(.grouped)
  }
}
