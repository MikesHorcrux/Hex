import HexCore
import HexIPC
import SwiftUI

struct AgentCodingPanelView: View {
  @State private var model: AgentCodingWorkspaceModel
  @State private var tab = "processes"
  @Environment(\.dismiss) private var dismiss
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
        Button("Done") { dismiss() }
      }
      Picker("Workspace view", selection: $tab) {
        Text("Processes").tag("processes")
        Text("Changes").tag("changes")
      }.pickerStyle(.segmented)
      if tab == "changes" {
        AgentChangesReviewView(
          review: model.review, refresh: { Task { await model.loadChanges() } },
          earlier: { Task { await model.loadChanges(earlier: true) } },
          openPatch: { id, index in Task { await model.loadPatch(id, index: index) } })
      } else {
        HStack(alignment: .top, spacing: 16) {
          List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
            ForEach(model.sessions) { session in
              VStack(alignment: .leading, spacing: 4) {
                Text(URL(fileURLWithPath: session.executable).lastPathComponent).fontWeight(.medium)
                Text(session.phase + (session.retained ? " · retained" : "")).font(.caption)
                  .foregroundStyle(.secondary)
              }.tag(session.id)
            }
          }.frame(width: 180)
          VStack(alignment: .leading, spacing: 10) {
            if let session = model.selected {
              Text(([session.executable] + session.arguments).joined(separator: " ")).font(
                .caption.monospaced()
              ).lineLimit(3).textSelection(.enabled)
              HStack {
                Text(session.phase.capitalized)
                if let code = session.exitCode { Text("Exit \(code)") }
                if let signal = session.signal { Text("Signal \(signal)") }
                if session.terminal {
                  Text(session.cleanupConfirmed ? "Group cleanup confirmed" : "Cleanup unconfirmed")
                }
              }.font(.caption).foregroundStyle(.secondary)
              if !session.explanation.isEmpty {
                Text(session.explanation).font(.caption).foregroundStyle(.orange)
              }
              if model.omittedBytes > 0 {
                HStack {
                  Text("Showing the latest 64 KiB. Earlier output remains saved.").font(.caption)
                  Button("Read from start") { model.select(session.id) }
                }
              }
              ScrollView([.vertical, .horizontal]) {
                Text(String(decoding: model.output, as: UTF8.self))
                  .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                  .frame(maxWidth: .infinity, alignment: .topLeading).padding(10)
              }.defaultScrollAnchor(.topLeading, for: .alignment)
                .background(.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
              HStack {
                TextField("Input (Send adds a newline)", text: $model.draft)
                  .textFieldStyle(.roundedBorder).onSubmit { Task { await model.send(.input) } }
                Button("Send") { Task { await model.send(.input) } }
              }.disabled(session.terminal || model.sending || model.pendingCommand != nil)
              HStack {
                Button("Interrupt") { Task { await model.send(.interrupt) } }.disabled(
                  model.pendingCommand != nil)
                Button("Send EOF") { Task { await model.send(.eof) } }.disabled(
                  model.pendingCommand != nil)
                Spacer()
                Button("Stop process", role: .destructive) { Task { await model.send(.stop) } }
              }.disabled(session.terminal || model.sending)
            } else {
              ContentUnavailableView(
                "No process sessions", systemImage: "terminal",
                description: Text(
                  "Commands and REPLs started by this conversation will appear here."))
            }
          }
        }
      }
      if tab == "processes" {
        HStack {
          if model.sessions.count == 50 { Button("Earlier sessions") { model.earlierSessions() } }
          if model.pageBefore != nil { Button("Newest sessions") { model.newestSessions() } }
        }
      }
      if let message = model.operationMessage {
        HStack {
          Text(message).font(.caption)
          if model.pendingCommand != nil {
            Button("Check receipt") { Task { await model.retryCommand() } }.disabled(model.sending)
          }
        }
      }
      if let error = model.error { Text(error).foregroundStyle(.red).font(.caption) }
    }.padding(20).frame(minWidth: 820, minHeight: 580).tint(HexBrandPalette.coral)
      .sheet(item: $model.patchPreview) { AgentPatchPreviewView(preview: $0) }
      .task {
        while !Task.isCancelled {
          if tab == "processes" { await model.refresh() }
          do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
      }
      .onChange(of: tab) { _, value in if value == "changes" { Task { await model.loadChanges() } }
      }
  }
}
