import HexCore
import HexIPC
import SwiftUI

struct AgentTasksView: View {
  @Bindable var model: AgentTaskWorkspaceModel
  @Bindable var workspace: AgentWorkspaceModel
  @State private var artifact: ArtifactReference?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let task = model.selected {
        Text(task.title).font(.title2.bold()).lineLimit(3)
        Text(task.explanation).foregroundStyle(.secondary)
          .accessibilityIdentifier("durableTaskStatus")
        HStack {
          Picker(
            "Attempt",
            selection: Binding(get: { model.historicalRunID }, set: { model.selectAttempt($0) })
          ) {
            Text("Latest (\(task.attemptCount))").tag(nil as AgentRunID?)
            ForEach(model.attempts) { attempt in
              Text("Attempt \(attempt.number)").tag(Optional(attempt.runID))
            }
          }.frame(maxWidth: 240)
          if (model.attempts.last?.number ?? 1) > 1 {
            Button("Earlier attempts") { Task { await model.olderAttempts() } }
          }
          if model.inspectingHistory {
            Button("Previous page") { Task { await model.previousHistoryPage() } }
              .disabled(model.historyPageStarts.count < 2)
            Button("Next page") { Task { await model.historyPage(after: model.sequence) } }
              .disabled(!model.historyHasMore)
            Button("Latest activity") { model.selectAttempt(model.historicalRunID) }
          } else {
            Button("Inspect saved history") { Task { await model.historyPage(after: 0) } }
          }
        }
        if !task.phase.isTerminal {
          HStack {
            Button("Pause") { Task { await model.control(.pause) } }
              .disabled(task.phase == .paused || task.phase == .pausing || task.phase == .blocked)
            Button("Resume") { Task { await model.control(.resume) } }
              .disabled(task.attemptPending || task.phase == .blocked)
            Button("Cancel task", role: .destructive) { Task { await model.control(.cancel) } }
              .disabled(task.phase == .cancelling)
          }.disabled(model.isSubmitting)
          HStack {
            TextField(
              task.phase == .blocked
                ? "What did you verify, and what should happen next?" : "Steer this task…",
              text: $model.steering, axis: .vertical
            )
            .accessibilityIdentifier("taskSteering")
            Button(task.phase == .blocked ? "Reconcile and continue" : "Apply steering") {
              let action: GatewayTaskRequest.Action =
                task.phase == .blocked
                ? .reconcile(model.steering) : .steer(model.steering)
              Task { await model.control(action) }
            }.disabled(
              model.steering.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || model.isSubmitting)
          }
        }
        if model.items.isEmpty {
          ContentUnavailableView(
            "Waiting for recorded activity", systemImage: "text.bubble",
            description: Text(
              model.inspectingHistory
                ? "This page contains execution metadata. Use Next page to continue."
                : task.explanation))
        } else {
          AgentConversationView(
            items: model.items, onPromptSuggestion: { model.draft = $0 },
            onOpenArtifact: { artifact = $0 })
        }
        if !model.inspectingHistory, model.historicalRunID == nil,
          let request = model.approvals.first
        {
          AgentToolAuthorizationView(request: request, isSubmitting: model.isSubmitting) {
            choice in
            Task { await model.decide(request, choice: choice) }
          }
        }
      } else {
        ContentUnavailableView(
          "No task selected", systemImage: "checklist",
          description: Text("Queue work below. Hex keeps it when this window closes."))
      }
      if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
      AgentTaskComposerView(model: model, workspace: workspace, onSubmit: submit)
    }.padding().frame(minWidth: 500)
      .background(HexBrandPalette.canvas)
      .sheet(isPresented: Binding(get: { artifact != nil }, set: { if !$0 { artifact = nil } })) {
        if let artifact {
          AgentArtifactPreviewView(reference: artifact, client: model.client).frame(
            minWidth: 640, minHeight: 500)
        }
      }
      .task {
        while !Task.isCancelled {
          await model.refresh()
          do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
      }
  }

  private func submit() {
    let text = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
    let request = GatewayStartRunRequest(
      runID: AgentRunID(),
      modelID: ModelID(rawValue: workspace.resolvedComposerModelID),
      initialMessages: [Message(role: .user, content: [.text(text)])],
      options: InferenceOptions(reasoningEffort: workspace.selectedComposerEffort.inferenceValue),
      authorizationMode: workspace.selectedComposerAuthorizationMode)
    Task { await model.submit(request, title: String(text.prefix(160))) }
  }
}
