import Observation
import SwiftUI

struct HexOnboardingPermissionsView: View {
  @Bindable var model: HexResidentSetupModel
  @Bindable var startAtLogin: HexStartAtLoginModel
  @Bindable var accessibilityPermission: HexAccessibilityPermissionModel

  var body: some View {
    Form {
      Section {
        HexInlineNoticeView(
          message:
            "You choose when Hex asks. macOS separately decides which protected parts of your Mac it may use.",
          systemImage: "hand.raised.fill",
          tint: HexBrandPalette.coral
        )
      }
      HexAuthorizationModePickerView(model: model)
      HexComputerAccessView(
        model: model,
        accessibilityPermission: accessibilityPermission,
        startAtLogin: startAtLogin
      )

      if let errorMessage = model.errorMessage {
        HexInlineNoticeView(
          message: errorMessage,
          systemImage: "exclamationmark.triangle.fill",
          tint: .orange
        )
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .tint(HexBrandPalette.coral)
  }
}
