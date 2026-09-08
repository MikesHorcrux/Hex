import HexCore
import HexIPC
import SwiftUI

struct AgentChatStatusView: View {
  @Bindable var model: AgentChatWorkspaceModel
  let work: AgentTaskRecord
  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      if work.phase == .running || work.phase == .pausing || work.phase == .cancelling {
        ProgressView().controlSize(.small)
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(work.phase == .running ? "Hex is working" : work.explanation)
          .font(.callout).accessibilityIdentifier("conversationWorkStatus")
        if work.phase == .blocked {
          Text("Check the affected state, then describe what happened below to continue.")
            .font(.caption).foregroundStyle(.secondary)
        } else if work.phase == .paused {
          Text("New messages are saved here. Resume when you are ready.")
            .font(.caption).foregroundStyle(.secondary)
        }
        if model.work.contains(where: { $0.id != work.id && $0.phase == .queued }) {
          Text("A follow-up is queued after this work.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer()
      if work.phase == .paused {
        Button("Resume") { Task { await model.control(.resume) } }
      } else if work.phase != .blocked && work.phase != .cancelling {
        Button("Pause") { Task { await model.control(.pause) } }.disabled(work.phase == .pausing)
      }
      Button("Cancel", role: .destructive) { Task { await model.control(.cancel) } }
        .disabled(work.phase == .cancelling)
    }.disabled(model.isSubmitting || model.pending != nil)
  }
}
