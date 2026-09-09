import HexCore
import HexIPC
import SwiftUI

struct AgentChatWorkspaceView: View {
  @Bindable var model: AgentChatWorkspaceModel
  @Bindable var workspace: AgentWorkspaceModel
  @State private var artifact: ArtifactReference?
  @State private var showsDetails = false
  @State private var showsCoding = false
  @State private var showsRename = false
  @State private var titleDraft = ""

  var body: some View {
    NavigationSplitView {
      AgentChatSidebarView(model: model)
        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 290)
    } detail: {
      VStack(spacing: 0) {
        if let error = model.error ?? workspace.errorMessage {
          ErrorBannerView(
            message: error,
            onRetry: {
              Task {
                await model.prepareHistory(workspace: workspace)
                await model.refresh()
              }
            },
            onDismiss: {
              model.error = nil
              workspace.dismissError()
            })
        }
        AgentConversationView(
          items: model.items, onPromptSuggestion: { model.draft = $0 },
          onOpenArtifact: { artifact = $0 },
          hasEarlierMessages: model.hasEarlier && model.selectedID != nil,
          showsLatestButton: model.showingEarlier, isLoadingHistory: model.isLoading,
          onEarlierMessages: { Task { await model.earlier() } }, onLatestMessages: model.latest,
          collapsesTools: true
        )
        .id(model.selectedID ?? model.newID)
        if let id = model.selectedID,
          let client = model.client as? any HexGatewayProcessSessionClient
        {
          AgentProcessActivityView(client: client, conversationID: id, open: { showsCoding = true })
            .id(id).frame(maxWidth: 760).padding(.horizontal, 24)
        }
        if let active = model.activeWork {
          AgentChatStatusView(model: model, work: active)
            .frame(maxWidth: 760).padding(.horizontal, 24).padding(.top, 8)
        }
        if model.activeWork != nil, let request = model.execution.approvals.first {
          AgentToolAuthorizationView(request: request, isSubmitting: model.isSubmitting) { choice in
            Task { await model.execution.decide(request, choice: choice) }
          }.frame(maxWidth: 760).padding(.horizontal, 24).padding(.top, 8)
        }
        AgentChatComposerView(model: model, workspace: workspace)
          .frame(maxWidth: 760)
          .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 20)
      }
      .background(HexBrandPalette.canvas)
      .navigationTitle(model.selected?.title ?? "New conversation")
      .toolbar {
        if workspace.connectionState != .connected {
          Button(
            workspace.connectionState == .connecting ? "Connecting…" : "Connect",
            systemImage: "bolt"
          ) {
            workspace.connectFromControl()
          }
          .disabled(workspace.connectionState == .connecting)
        }
        if model.selectedID != nil, model.client is any HexGatewayProcessSessionClient {
          Button("Processes and changes", systemImage: "terminal") { showsCoding = true }
        }
        if model.currentWork != nil {
          Button("Execution history", systemImage: "sidebar.right") { showsDetails = true }
            .help("Show the work and saved attempts behind this conversation")
        }
        Menu("Conversation", systemImage: "ellipsis") {
          if model.selectedID != nil {
            Button("Rename") {
              titleDraft = model.selected?.title ?? ""
              showsRename = true
            }
            Button(model.selected?.archivedAt == nil ? "Archive" : "Unarchive") {
              if let id = model.selectedID {
                Task { await model.archive(id, archived: model.selected?.archivedAt == nil) }
              }
            }.disabled(model.activeWork != nil)
            Divider()
          }
          if workspace.connectionState == .connected {
            Button("Disconnect", systemImage: "bolt.slash", action: workspace.disconnectFromControl)
          }
        }
        .disabled(model.isSubmitting || model.pending != nil)
      }
    }
    .navigationSplitViewStyle(.balanced).tint(HexBrandPalette.coral)
    .frame(minWidth: 780, minHeight: 580)
    .alert("Rename conversation", isPresented: $showsRename) {
      TextField("Title", text: $titleDraft)
      Button("Save") { Task { await model.rename(titleDraft) } }
      Button("Cancel", role: .cancel) {}
    }
    .sheet(isPresented: $showsCoding) {
      if let id = model.selectedID, let client = model.client as? any HexGatewayProcessSessionClient
      {
        AgentCodingPanelView(client: client, conversationID: id, taskID: model.currentWork?.id)
      }
    }
    .sheet(isPresented: $showsDetails) {
      AgentExecutionDetailsView(
        client: model.client, taskClient: model.taskClient,
        conversationID: model.selectedID, selectedTaskID: model.currentWork?.id
      )
      .frame(minWidth: 760, minHeight: 600)
    }
    .sheet(isPresented: Binding(get: { artifact != nil }, set: { if !$0 { artifact = nil } })) {
      if let artifact {
        AgentArtifactPreviewView(reference: artifact, client: model.client)
          .frame(minWidth: 640, minHeight: 500)
      }
    }
    .task {
      while !Task.isCancelled {
        if workspace.connectionState == .connected {
          await model.prepareHistory(workspace: workspace)
          await model.refresh()
        }
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
      }
    }
  }
}
