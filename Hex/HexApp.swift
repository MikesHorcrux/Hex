import AppKit
import SwiftUI

@main
struct HexApp: App {
  @State private var workspace: AgentWorkspaceModel
  @State private var residentGateway: HexResidentGatewayModel
  @State private var startAtLogin: HexStartAtLoginModel
  private let route: HexGatewayRoute

  init() {
    let configuration = HexDeveloperConfiguration(
      environment: ProcessInfo.processInfo.environment
    )
    self.init(
      client: HexLiveAgentClient(configuration: configuration),
      modelID: configuration.modelIDForInterface,
      route: configuration.gatewayRoute
    )
  }

  init(
    client: any HexAgentClient = PreviewHexAgentClient(),
    modelID: String = "preview",
    route: HexGatewayRoute = .residentXPC(),
    residentGatewayController: any HexResidentGatewayControlling =
      HexUnavailableResidentGatewayController(),
    lifecycleController: any HexGatewayLifecycleControlling =
      HexSMAppServiceLifecycleController()
  ) {
    self.route = route
    _workspace = State(initialValue: AgentWorkspaceModel(client: client, modelID: modelID))
    _residentGateway = State(
      initialValue: HexResidentGatewayModel(controller: residentGatewayController)
    )
    _startAtLogin = State(initialValue: HexStartAtLoginModel(controller: lifecycleController))
  }

  var body: some Scene {
    WindowGroup(id: "main") {
      ContentView(model: workspace)
    }

    MenuBarExtra {
      HexMenuBarView(
        workspace: workspace,
        gateway: residentGateway,
        startAtLogin: startAtLogin,
        route: route,
        onQuitHexUI: {
          // This only terminates the control surface. The resident LaunchAgent is a separate
          // process and is intentionally not stopped by closing or quitting the app UI.
          NSApplication.shared.terminate(nil)
        }
      )
    } label: {
      Image(systemName: menuBarSymbol)
        .accessibilityLabel("Hex gateway")
    }
    .menuBarExtraStyle(.menu)
  }

  private var menuBarSymbol: String {
    switch residentGateway.status {
    case .paused:
      "pause.circle.fill"
    case .active:
      "bolt.circle.fill"
    case .idle:
      "checkmark.circle.fill"
    case .unavailable:
      guard workspace.connectionState == .connected else {
        return "exclamationmark.circle"
      }
      return workspace.isRunActive ? "bolt.circle.fill" : "checkmark.circle.fill"
    }
  }
}
