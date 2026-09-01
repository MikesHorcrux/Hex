import SwiftUI

@main
struct HexApp: App {
  @State private var workspace: AgentWorkspaceModel

  init() {
    let configuration = HexDeveloperConfiguration(
      environment: ProcessInfo.processInfo.environment
    )
    self.init(
      client: HexLiveAgentClient(configuration: configuration),
      modelID: configuration.modelIDForInterface
    )
  }

  init(
    client: any HexAgentClient = PreviewHexAgentClient(),
    modelID: String = "preview"
  ) {
    _workspace = State(initialValue: AgentWorkspaceModel(client: client, modelID: modelID))
  }

  var body: some Scene {
    WindowGroup {
      ContentView(model: workspace)
    }
  }
}
