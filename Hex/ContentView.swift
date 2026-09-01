import Observation
import SwiftUI

struct ContentView: View {
  @Bindable var model: AgentWorkspaceModel

  var body: some View {
    NavigationSplitView {
      SidebarView(model: model)
        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
    } detail: {
      VStack(spacing: 0) {
        GatewayStatusView(
          connectionState: model.connectionState,
          runState: model.runState,
          runSummary: model.runSummary,
          onConnect: model.connectFromControl,
          onDisconnect: model.disconnectFromControl
        )

        if let error = model.errorMessage {
          ErrorBannerView(
            message: error,
            onRetry: model.retryConnection,
            onDismiss: model.dismissError
          )
        }

        ConversationView(items: model.transcript)

        if let request = model.pendingAuthorization {
          ToolAuthorizationView(
            request: request,
            isSubmitting: model.isSubmittingAuthorization,
            onChoice: model.decideAuthorization
          )
          .padding(.horizontal, 20)
          .padding(.bottom, 12)
        }

        ComposerView(
          draft: $model.draft,
          canSend: model.canSend,
          isRunning: model.isRunActive,
          onSend: model.send,
          onCancel: model.cancel
        )
      }
      .background(Color(nsColor: .windowBackgroundColor))
    }
    .task {
      await model.connect()
    }
  }
}

#Preview {
  ContentView(model: AgentWorkspaceModel(client: PreviewHexAgentClient()))
}
