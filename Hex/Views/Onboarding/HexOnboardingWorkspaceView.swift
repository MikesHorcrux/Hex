import Observation
import SwiftUI

struct HexOnboardingWorkspaceView: View {
  @Bindable var model: HexResidentSetupModel

  var body: some View {
    Form {
      Section {
        HexInlineNoticeView(
          message:
            "Hex keeps its built-in coding work inside the folder you choose. You can change it later.",
          systemImage: "folder.badge.gearshape",
          tint: HexBrandPalette.coral
        )
      }

      HexResidentConfigurationFormView(model: model)

      if let errorMessage = model.errorMessage {
        HexInlineNoticeView(
          message: errorMessage,
          systemImage: "exclamationmark.triangle.fill",
          tint: .orange
        )
      }
      HexResidentSetupLoadRetryView(model: model)
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .tint(HexBrandPalette.coral)
    .task {
      await model.load()
    }
  }
}
