import Observation
import SwiftUI

struct HexOnboardingToolsView: View {
  @Bindable var model: HexResidentSetupModel

  var body: some View {
    Form {
      HexMCPIntegrationsView(model: model)

      if let statusMessage = model.statusMessage {
        HexInlineNoticeView(
          message: statusMessage,
          systemImage: model.isInstallingManagedTool
            ? "arrow.down.circle.fill" : "checkmark.circle.fill",
          tint: model.isInstallingManagedTool
            ? HexBrandPalette.coral : HexBrandPalette.successInk
        )
      }

      if let errorMessage = model.errorMessage {
        HexInlineNoticeView(
          message: "\(errorMessage) Turn the tool on again to retry.",
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
