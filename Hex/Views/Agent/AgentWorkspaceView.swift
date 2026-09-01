import Observation
import SwiftUI

struct AgentWorkspaceView: View {
  @Bindable var model: AgentWorkspaceModel
  let connectOnAppear: Bool

  init(model: AgentWorkspaceModel, connectOnAppear: Bool = true) {
    _model = Bindable(model)
    self.connectOnAppear = connectOnAppear
  }

  var body: some View {
    NavigationSplitView {
      AgentSidebarView(model: model)
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

        AgentConversationView(items: model.transcript)

        if let request = model.pendingAuthorization {
          AgentToolAuthorizationView(
            request: request,
            isSubmitting: model.isSubmittingAuthorization,
            onChoice: model.decideAuthorization
          )
          .padding(.horizontal, 20)
          .padding(.bottom, 12)
        }

        AgentComposerView(
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
      guard connectOnAppear else { return }
      await model.connect()
    }
  }
}

#Preview {
  AgentWorkspaceView(model: AgentWorkspaceModel(client: PreviewHexAgentClient()))
}
