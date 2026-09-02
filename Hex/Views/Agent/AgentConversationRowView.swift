import SwiftUI

struct AgentConversationRowView: View {
  let item: ConversationItem

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: icon)
        .font(.callout.weight(.semibold))
        .foregroundStyle(iconColor)
        .frame(width: 24, height: 24)
        .background(iconColor.opacity(0.1), in: Circle())

      VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: 7) {
          Text(item.role.label)
            .font(.callout.weight(.semibold))
          Text(item.timestamp, style: .time)
            .font(.caption)
            .foregroundStyle(.tertiary)
          if item.isStreaming {
            ProgressView()
              .controlSize(.mini)
              .accessibilityLabel("Hex is responding")
          }
        }

        if item.role == .event {
          Text(item.text.isEmpty ? "…" : item.text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        } else {
          MarkdownMessageView(markdown: item.text.isEmpty ? "…" : item.text)
        }
      }
      .frame(maxWidth: 760, alignment: .leading)

      Spacer(minLength: 0)
    }
    .padding(.vertical, 9)
  }

  private var icon: String {
    switch item.role {
    case .user:
      "person.fill"
    case .assistant:
      "sparkles"
    case .tool:
      "wrench.and.screwdriver"
    case .event:
      "info.circle"
    }
  }

  private var iconColor: Color {
    switch item.role {
    case .user:
      .accentColor
    case .assistant:
      .primary
    case .tool:
      .orange
    case .event:
      .secondary
    }
  }
}
