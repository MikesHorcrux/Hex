import Observation
import SwiftUI

struct AgentSidebarView: View {
  @Bindable var model: AgentWorkspaceModel

  var body: some View {
    List(selection: conversationSelection) {
      Section("Conversations") {
        if model.isRestoringConversations {
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.small)
            Text("Restoring history…")
              .foregroundStyle(.secondary)
          }
        } else if model.orderedConversations.isEmpty {
          Text("No conversations yet")
            .foregroundStyle(.secondary)
        } else {
          ForEach(model.orderedConversations) { conversation in
            HStack(spacing: 9) {
              Image(systemName: "bubble.left")
                .foregroundStyle(.secondary)
              VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title)
                  .lineLimit(1)
                Text(conversation.updatedAt, style: .relative)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer(minLength: 0)
            }
            .tag(conversation.id)
            .accessibilityLabel(conversation.title)
          }
        }
      }
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .bottom) {
      HStack(spacing: 8) {
        Circle()
          .fill(connectionColor)
          .frame(width: 8, height: 8)
        VStack(alignment: .leading, spacing: 1) {
          Text(model.connectionState.label)
            .font(.caption.weight(.medium))
          Text(model.runSummary)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer()
        if model.connectionState == .connecting {
          ProgressView()
            .controlSize(.small)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
      .background(.bar)
    }
  }

  private var conversationSelection: Binding<UUID?> {
    Binding(
      get: { model.selectedConversationID },
      set: { selection in
        guard let selection else { return }
        model.selectConversation(selection)
      }
    )
  }

  private var connectionColor: Color {
    switch model.connectionState {
    case .connected:
      .green
    case .connecting:
      .orange
    case .disconnected:
      .secondary
    }
  }
}
