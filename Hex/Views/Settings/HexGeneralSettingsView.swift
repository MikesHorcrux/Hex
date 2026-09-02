import Observation
import SwiftUI

struct HexGeneralSettingsView: View {
  @Bindable var workspace: AgentWorkspaceModel
  @Bindable var startAtLogin: HexStartAtLoginModel
  let route: HexGatewayRoute
  let suppressAutomaticRefresh: Bool
  let onRunSetupAgain: () -> Void

  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Form {
      Section {
        LabeledContent("Gateway route", value: route.label)
        LabeledContent("Start at login", value: startAtLogin.status.label)

        if route.kind == .developerInProcess {
          Text("Always-on mode is available with the resident gateway route.")
            .foregroundStyle(.secondary)
        } else if startAtLogin.isAvailable {
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
        Text("Resident agent")
      } footer: {
        Text("The resident gateway can stay active after the Hex window closes.")
      }

      Section {
        Button("Run Setup Again") {
          onRunSetupAgain()
          openWindow(id: "main")
        }
        .disabled(workspace.isRunActive)
      } header: {
        Text("Setup")
      } footer: {
        Text("Your saved settings are kept and prefilled. Active runs must finish first.")
      }
    }
    .formStyle(.grouped)
    .task {
      guard !suppressAutomaticRefresh else { return }
      await startAtLogin.refresh()
    }
  }
}
