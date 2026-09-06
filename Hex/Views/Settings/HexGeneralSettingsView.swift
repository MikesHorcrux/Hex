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
        LabeledContent(
          "Agent mode",
          value: route.kind == .residentXPC ? "Always-on" : "Developer mode"
        )
        LabeledContent("Always-on agent", value: startAtLogin.status.label)

        if route.kind == .developerInProcess {
          HexInlineNoticeView(
            message: "Always-on mode is unavailable while Hex is running in developer mode.",
            systemImage: "hammer",
            tint: HexBrandPalette.apricot
          )
        } else if startAtLogin.isAvailable {
          Button(startAtLogin.buttonTitle) {
            startAtLogin.toggle()
          }
          .buttonStyle(.hexSecondaryAction)
          .disabled(!startAtLogin.canChange)

          if startAtLogin.status == .requiresApproval {
            Button("Open Login Items Settings") {
              Task {
                await startAtLogin.openLoginItemsSettings()
              }
            }
            .buttonStyle(.hexSecondaryAction)
          }
        } else if let readinessMessage = startAtLogin.readinessMessage {
          HexInlineNoticeView(
            message: readinessMessage,
            systemImage: "exclamationmark.triangle.fill",
            tint: .orange
          )
        }

        if let message = startAtLogin.message {
          HexInlineNoticeView(
            message: message,
            systemImage: "exclamationmark.triangle.fill",
            tint: .orange
          )
        }
      } header: {
        Text("Availability")
      } footer: {
        Text("When enabled, Hex stays ready after its window closes and returns when you sign in.")
      }

      Section {
        Button("Run Setup Again") {
          onRunSetupAgain()
          openWindow(id: "main")
        }
        .buttonStyle(.hexSecondaryAction)
        .disabled(workspace.isRunActive)
      } header: {
        Text("Guided setup")
      } footer: {
        Text("Walk through the seven setup steps again. Your saved choices stay filled in.")
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .tint(HexBrandPalette.coral)
    .task {
      guard !suppressAutomaticRefresh else { return }
      await startAtLogin.refresh()
    }
  }
}
