import SwiftUI

struct AgentWorkspaceView: View {
  @Bindable var model: AgentWorkspaceModel
  var connectOnAppear = true

  var body: some View {
    if let chat = model.chatWorkspace {
      AgentChatWorkspaceView(model: chat, workspace: model)
        .task {
          if connectOnAppear { await model.connectAutomatically() }
          await chat.prepareHistory(workspace: model)
          await chat.refresh()
        }
    } else {
      AgentLegacyWorkspaceView(model: model, connectOnAppear: connectOnAppear)
    }
  }
}

#Preview {
  AgentWorkspaceView(model: AgentWorkspaceModel(client: PreviewHexAgentClient()))
}
