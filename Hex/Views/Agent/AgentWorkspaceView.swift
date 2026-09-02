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
        .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
    } detail: {
      VStack(spacing: 0) {
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
      .navigationTitle(model.selectedConversationTitle ?? "Hex")
      .toolbar {
        ToolbarItemGroup {
          Button {
            model.newConversation()
          } label: {
            Label("New conversation", systemImage: "square.and.pencil")
          }

          if model.connectionState == .connected {
            Button(action: model.disconnectFromControl) {
              Label("Disconnect", systemImage: "bolt.slash")
            }
            .disabled(model.isRunActive)
          } else {
            Button(action: model.connectFromControl) {
              Label("Connect", systemImage: "bolt")
            }
            .disabled(model.connectionState == .connecting)
          }

          SettingsLink {
            Label("Settings", systemImage: "gearshape")
          }
        }
      }
    }
    .navigationSplitViewStyle(.balanced)
    .task {
      await model.restoreConversationHistory()
      guard connectOnAppear else { return }
      await model.connect()
    }
  }
}

#Preview {
  AgentWorkspaceView(model: AgentWorkspaceModel(client: PreviewHexAgentClient()))
}
