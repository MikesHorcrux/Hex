import HexCore
import Observation
import SwiftUI

struct HexOnboardingReadyView: View {
  @Bindable var residentSetup: HexResidentSetupModel
  @Bindable var startAtLogin: HexStartAtLoginModel

  var body: some View {
    Form {
      Section("Agent") {
        LabeledContent("Model", value: residentSetup.modelID)
        LabeledContent("Workspace", value: residentSetup.workspaceDisplayName)
        LabeledContent(
          "Approvals",
          value: residentSetup.authorizationMode == .fullAccess ? "Full Access" : "Ask"
        )
      }

      Section {
        LabeledContent("Resident gateway", value: startAtLogin.status.label)

        if startAtLogin.isAvailable {
          Button(startAtLogin.buttonTitle) {
            startAtLogin.toggle()
          }
          .disabled(!startAtLogin.canChange)

          if startAtLogin.status == .requiresApproval {
            Button("Open Login Items Settings") {
              Task {
                await startAtLogin.openLoginItemsSettings()
              }
            }
          }
        } else if let readinessMessage = startAtLogin.readinessMessage {
          Text(readinessMessage)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if let message = startAtLogin.message {
          Text(message)
            .font(.caption)
            .foregroundStyle(.orange)
        }
      } header: {
        Text("Always on")
      } footer: {
        Text("Start at login keeps the resident gateway available when the Hex window is closed.")
      }

      Section {
        Label(
          "Hex is configured and ready for its first conversation.",
          systemImage: "checkmark.circle.fill"
        )
        .foregroundStyle(.green)
      }
    }
    .formStyle(.grouped)
    .task {
      await startAtLogin.refresh()
    }
  }
}
