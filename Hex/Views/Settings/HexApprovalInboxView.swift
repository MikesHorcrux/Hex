import HexCore
import HexIPC
import SwiftUI

struct HexApprovalInboxView: View {
  @Bindable var model: HexApprovalInboxModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Approval inbox").font(.title2.bold()).accessibilityIdentifier("approvalInboxTitle")
        Spacer()
        if model.isBusy { ProgressView().controlSize(.small) }
        Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
          .disabled(model.isBusy)
          .accessibilityIdentifier("refreshApprovalInbox")
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("closeApprovalInbox")
      }
      Text(
        "Decisions for conversations and scheduled work. Closing Hex’s window leaves these actions paused in Hex Agent; restarting the agent cancels them. Old requests are never approved automatically."
      )
      .font(.callout).foregroundStyle(.secondary)
      if let message = model.message {
        Text(message).font(.callout).textSelection(.enabled)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if let inbox = model.inbox {
            Text("Scheduled work uses: \(inbox.defaultMode.permissionTitle)")
              .font(.callout.weight(.semibold))
            if inbox.requests.isEmpty {
              Label("No actions waiting for approval", systemImage: "checkmark.circle")
                .padding(.vertical, 12)
            }
            ForEach(inbox.requests) { request in
              VStack(alignment: .leading, spacing: 6) {
                Text("Run \(request.runID.description)").font(.caption.monospaced())
                  .foregroundStyle(.secondary).textSelection(.enabled)
                AgentToolAuthorizationView(request: request, isSubmitting: model.isBusy) { choice in
                  Task { await model.decide(request, choice: choice) }
                }
              }
            }
            Divider()
            Text("Remembered for this agent session").font(.headline)
            Text(
              "Session approvals apply to the exact operation and target across conversations and scheduled work, until Hex Agent restarts. Revoking affects future checks; it does not undo actions already authorized. Full access and automatic low-risk reads do not use these grants."
            )
            .font(.caption).foregroundStyle(.secondary)
            if inbox.sessionGrants.isEmpty {
              Text("No remembered approvals.").foregroundStyle(.secondary)
            }
            ForEach(inbox.sessionGrants, id: \.self) { grant in
              HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                  Text("\(grant.capability.rawValue) · \(grant.operation)").font(.callout.bold())
                  Text(grant.resource ?? "This operation without a specific target")
                    .font(.caption.monospaced()).textSelection(.enabled)
                }
                Spacer()
                Button("Revoke", role: .destructive) { Task { await model.revoke(grant) } }
                  .disabled(model.isBusy)
              }
              .padding(12)
              .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
          } else if !model.isBusy {
            ContentUnavailableView(
              "Agent unavailable", systemImage: "antenna.radiowaves.left.and.right.slash",
              description: Text(
                "Connect or restart the canonical Hex Agent, then refresh. No permission is inferred."
              ))
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(22)
    .frame(minWidth: 620, idealWidth: 700, minHeight: 450, idealHeight: 650)
    .task {
      // Read-only polling exists only while this inbox is visible. A decision is never retried.
      while !Task.isCancelled {
        if scenePhase == .active { await model.refresh() }
        do { try await Task.sleep(for: .seconds(3)) } catch { return }
      }
    }
  }
}
