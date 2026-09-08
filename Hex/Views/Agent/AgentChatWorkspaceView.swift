import HexCore
import SwiftUI

struct AgentChatWorkspaceView: View {
  @Bindable var model: AgentChatWorkspaceModel
  @Bindable var workspace: AgentWorkspaceModel
  @State private var artifact: ArtifactReference?
  @State private var showsDetails = false
  @State private var showsRename = false
  @State private var titleDraft = ""

  var body: some View {
    NavigationSplitView {
      AgentChatSidebarView(model: model)
        .navigationSplitViewColumnWidth(min: 240, ideal: 264, max: 310)
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
          collapsesTools: true)
        if let active = model.activeWork {
          AgentChatStatusView(model: model, work: active).padding(.horizontal, 24)
        }
        if model.activeWork != nil, let request = model.execution.approvals.first {
          AgentToolAuthorizationView(request: request, isSubmitting: model.isSubmitting) { choice in
            Task { await model.execution.decide(request, choice: choice) }
          }.padding(.horizontal, 24)
        }
        AgentChatComposerView(model: model, workspace: workspace)
          .padding(.horizontal, 24).padding(.vertical, 14)
      }
      .background(HexBrandPalette.canvas)
      .navigationTitle(model.selected?.title ?? "New conversation")
      .toolbar {
        Button("New conversation", systemImage: "square.and.pencil") { model.select(nil) }
          .disabled(model.isSubmitting || model.pending != nil)
          .keyboardShortcut("n", modifiers: .command)
        if model.selectedID != nil {
          Menu("Conversation", systemImage: "ellipsis.circle") {
            Button("Rename") {
              titleDraft = model.selected?.title ?? ""
              showsRename = true
            }
            Button(model.selected?.archivedAt == nil ? "Archive" : "Unarchive") {
              if let id = model.selectedID {
                Task { await model.archive(id, archived: model.selected?.archivedAt == nil) }
              }
            }.disabled(model.activeWork != nil)
            if model.currentWork != nil {
              Button("Execution history") { showsDetails = true }
            }
          }
        }
        if workspace.connectionState == .connected {
          Button("Disconnect", systemImage: "bolt.slash", action: workspace.disconnectFromControl)
        } else {
          Button("Connect", systemImage: "bolt", action: workspace.connectFromControl)
            .disabled(workspace.connectionState == .connecting)
        }
        SettingsLink { Label("Settings", systemImage: "gearshape") }
      }
    }
    .navigationSplitViewStyle(.balanced).tint(HexBrandPalette.coral)
    .frame(minWidth: 900, minHeight: 650)
    .alert("Rename conversation", isPresented: $showsRename) {
      TextField("Title", text: $titleDraft)
      Button("Save") { Task { await model.rename(titleDraft) } }
      Button("Cancel", role: .cancel) {}
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
