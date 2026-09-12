import HexCore
import HexIPC
import SwiftUI

struct AgentCodingPanelView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: AgentCodingWorkspaceModel
  @State private var tab = AgentCodingTab.processes

  init(model: AgentCodingWorkspaceModel) { _model = State(initialValue: model) }

  init(client: any HexGatewayProcessSessionClient, conversationID: UUID, taskID: UUID?) {
    _model = State(
      initialValue: AgentCodingWorkspaceModel(
        client: client, conversationID: conversationID, taskID: taskID))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Coding workspace").font(.title2.bold())
        Spacer()
        Button("Done") { dismiss() }.buttonStyle(.hexSecondaryAction)
      }
      HexSegmentedPicker(
        title: "Workspace view", options: AgentCodingTab.allCases, selection: $tab, label: \.title)
      switch tab {
      case .changes:
        AgentChangesReviewView(
          review: model.review, refresh: { Task { await model.loadChanges() } },
          earlier: { Task { await model.loadChanges(earlier: true) } },
          openPatch: { id, index in Task { await model.loadPatch(id, index: index) } })
      case .processes:
        HStack(alignment: .top, spacing: 16) {
          AgentProcessListView(
            sessions: model.sessions,
            selection: Binding(get: { model.selectedID }, set: { model.select($0) }))
          if let session = model.selected {
            AgentProcessDetailsView(
              session: session, output: model.output, omittedBytes: model.omittedBytes,
              sending: model.sending, hasPendingCommand: model.pendingCommand != nil,
              draft: $model.draft, readFromStart: { model.select(session.id) },
              send: { action in Task { await model.send(action) } })
          } else {
            ContentUnavailableView(
              "No process sessions", systemImage: "terminal",
              description: Text("Commands and REPLs started by this conversation will appear here.")
            )
          }
        }
        HStack {
          if model.sessions.count == 50 { Button("Earlier sessions") { model.earlierSessions() } }
          if model.pageBefore != nil { Button("Newest sessions") { model.newestSessions() } }
        }
        .buttonStyle(.hexSecondaryAction)
      }
      if let message = model.operationMessage {
        HStack {
          Text(message).font(.caption)
          if model.pendingCommand != nil {
            Button("Check receipt") { Task { await model.retryCommand() } }
              .buttonStyle(.hexSecondaryAction)
              .disabled(model.sending)
          }
        }
      }
      if let error = model.error { Text(error).foregroundStyle(.red).font(.caption) }
    }
    .padding(20)
    .frame(minWidth: 820, minHeight: 580)
    .background(HexBrandPalette.canvas)
    .tint(HexBrandPalette.coral)
    .sheet(item: $model.patchPreview) { AgentPatchPreviewView(preview: $0) }
    .task(id: tab) { await model.observe(tab: tab) }
  }
}
