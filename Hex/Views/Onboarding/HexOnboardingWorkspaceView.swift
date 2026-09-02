import Observation
import SwiftUI

struct HexOnboardingWorkspaceView: View {
  @Bindable var model: HexResidentSetupModel

  var body: some View {
    Form {
      Section {
        Text(
          "The workspace is Hex's coding boundary. Built-in read, search, edit, and terminal tools are rooted here."
        )
        .foregroundStyle(.secondary)
      }

      HexResidentConfigurationFormView(model: model)

      if let errorMessage = model.errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
      }
    }
    .formStyle(.grouped)
    .task {
      await model.load()
    }
  }
}
