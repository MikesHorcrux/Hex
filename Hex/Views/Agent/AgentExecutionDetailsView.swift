import HexCore
import HexIPC
import SwiftUI

struct AgentExecutionDetailsView: View {
  @State private var model: AgentTaskWorkspaceModel
  let conversationID: UUID?
  @Environment(\.dismiss) private var dismiss
  @State private var work: [AgentTaskRecord] = []
  @State private var next: UUID?
  init(
    client: any HexAgentClient, taskClient: any HexGatewayTaskClient,
    conversationID: UUID?, selectedTaskID: UUID?
  ) {
    self.conversationID = conversationID
    let projection = AgentTaskWorkspaceModel(client: client, taskClient: taskClient)
    projection.selectedID = selectedTaskID
    _model = State(initialValue: projection)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Execution history").font(.title2.bold())
        Spacer()
        Button("Done") { dismiss() }
      }
      Picker(
        "Request",
        selection: Binding(get: { model.selectedID }, set: { if let id = $0 { model.select(id) } })
      ) {
        ForEach(work) { item in
          Text("\(item.createdAt.formatted(date: .omitted, time: .standard)) · \(item.title)")
            .tag(Optional(item.id))
        }
      }
      if next != nil { Button("Earlier requests") { Task { await loadWork(more: true) } } }
      Picker(
        "Attempt",
        selection: Binding(get: { model.historicalRunID }, set: { model.selectAttempt($0) })
      ) {
        Text("Latest").tag(nil as AgentRunID?)
        ForEach(model.attempts) { attempt in
          Text("Attempt \(attempt.number)").tag(Optional(attempt.runID))
        }
      }
      if (model.attempts.last?.number ?? 1) > 1 {
        Button("Earlier attempts") { Task { await model.olderAttempts() } }
      }
      HStack {
        Button("First page") { Task { await model.historyPage(after: 0) } }
        Button("Previous page") { Task { await model.previousHistoryPage() } }.disabled(
          model.historyPageStarts.count < 2)
        Button("Next page") { Task { await model.historyPage(after: model.sequence) } }.disabled(
          !model.historyHasMore)
      }
      AgentConversationView(items: model.items, onPromptSuggestion: { _ in })
      if let error = model.error { Text(error).foregroundStyle(.red) }
    }.padding()
      .task {
        await loadWork(more: false)
        await loadAttempt()
      }
      .onChange(of: model.selectedID) { _, _ in Task { await loadAttempt() } }
      .onChange(of: model.historicalRunID) { _, _ in Task { await model.historyPage(after: 0) } }
  }
  private func loadWork(more: Bool) async {
    guard let conversationID else { return }
    do {
      let response = try await model.taskClient.taskOperation(
        .conversationTasks(conversationID, before: more ? next : nil, limit: 20))
      if more {
        work += response.tasks.filter { item in !work.contains(where: { $0.id == item.id }) }
      } else {
        work = response.tasks
      }
      next = response.next
      for record in response.tasks { model.update(record) }
      if let selectedID = model.selectedID, !work.contains(where: { $0.id == selectedID }),
        let record = try await model.taskClient.taskOperation(.read(selectedID)).tasks.first
      {
        work.insert(record, at: 0)
        model.update(record)
      }
      if model.selectedID == nil, let id = work.first?.id { model.select(id) }
    } catch { model.error = "Execution links could not be loaded." }
  }
  private func loadAttempt() async {
    guard let id = model.selectedID else { return }
    do {
      let attempts = try await model.taskClient.taskOperation(
        .attempts(id, before: nil, limit: 20)
      ).attempts
      guard model.selectedID == id else { return }
      model.attempts = attempts
    } catch { model.error = "Attempts could not be loaded." }
    await model.historyPage(after: 0)
  }
}
