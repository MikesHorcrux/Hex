import SwiftUI

struct ConversationView: View {
  let items: [ConversationItem]

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        if items.isEmpty {
          emptyState
        } else {
          LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(items) { item in
              conversationRow(item)
                .id(item.id)
            }
          }
          .padding(.horizontal, 20)
          .padding(.vertical, 24)
        }
      }
      .scrollIndicators(.automatic)
      .onChange(of: items.count) { _, _ in
        guard let lastID = items.last?.id else { return }
        withAnimation(.easeOut(duration: 0.18)) {
          proxy.scrollTo(lastID, anchor: .bottom)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyState: some View {
    VStack(spacing: 10) {
      Image(systemName: "sparkles")
        .font(.system(size: 30))
        .foregroundStyle(.tint)
      Text("Start the first agent run")
        .font(.title3.weight(.semibold))
      Text("Ask Hex to inspect a project, explain a decision, or take a permissioned action.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 390)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(40)
  }

  @ViewBuilder
  private func conversationRow(_ item: ConversationItem) -> some View {
    let isUser = item.role == .user
    let isEvent = item.role == .event
    HStack(alignment: .top, spacing: 10) {
      if isUser {
        Spacer(minLength: 70)
      }

      VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
        HStack(spacing: 7) {
          if !isUser {
            Image(systemName: icon(for: item.role))
              .foregroundStyle(color(for: item.role))
          }
          Text(item.role.label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color(for: item.role))
          Text(item.timestamp, style: .time)
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }

        HStack(alignment: .bottom, spacing: 8) {
          Text(item.text.isEmpty ? "…" : item.text)
            .font(isEvent ? .caption : .body)
            .foregroundStyle(isEvent ? .secondary : .primary)
            .textSelection(.enabled)
            .frame(maxWidth: 680, alignment: isUser ? .trailing : .leading)

          if item.isStreaming {
            ProgressView()
              .controlSize(.mini)
              .accessibilityLabel("Hex is responding")
          }
        }
        .padding(.horizontal, isEvent ? 0 : 13)
        .padding(.vertical, isEvent ? 0 : 10)
        .background(
          isEvent
            ? Color.clear
            : (isUser ? Color.accentColor.opacity(0.13) : Color(nsColor: .controlBackgroundColor)),
          in: RoundedRectangle(cornerRadius: 12)
        )
      }

      if !isUser {
        Spacer(minLength: 70)
      }
    }
  }

  private func icon(for role: ConversationItem.Role) -> String {
    switch role {
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

  private func color(for role: ConversationItem.Role) -> Color {
    switch role {
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
