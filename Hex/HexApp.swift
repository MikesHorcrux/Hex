import SwiftUI

@main
struct HexApp: App {
  @State private var workspace: AgentWorkspaceModel

  init() {
    self.init(client: PreviewHexAgentClient())
  }

  init(client: any HexAgentClient = PreviewHexAgentClient()) {
    _workspace = State(initialValue: AgentWorkspaceModel(client: client))
  }

  var body: some Scene {
    WindowGroup {
      ContentView(model: workspace)
    }
  }
}
