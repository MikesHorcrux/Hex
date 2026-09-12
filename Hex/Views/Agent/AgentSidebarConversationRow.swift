import SwiftUI

struct AgentSidebarConversationRow: View {
  let conversation: AgentConversation
  let canOrganize: Bool
  let canDelete: Bool
  let onRename: () -> Void
  let onArchive: () -> Void
  let onDelete: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: conversation.isArchived ? "archivebox" : "bubble.left.fill")
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(conversation.title)
          .font(.callout.weight(.medium))
          .lineLimit(1)
        Text(conversation.updatedAt, style: .relative)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(conversation.title)
    .accessibilityValue(conversation.isArchived ? "Archived conversation" : "Conversation")
    .contextMenu {
      Button("Rename…", action: onRename)
        .disabled(!canOrganize)
      Button(conversation.isArchived ? "Unarchive" : "Archive", action: onArchive)
        .disabled(!canOrganize)
      Divider()
      Button("Delete Conversation", role: .destructive, action: onDelete)
        .disabled(!canDelete)
    }
  }
}
