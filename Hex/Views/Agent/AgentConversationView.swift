import HexCore
import SwiftUI

struct AgentConversationView: View {
  let items: [ConversationItem]
  let onPromptSuggestion: (String) -> Void
  var onOpenArtifact: (ArtifactReference) -> Void = { _ in }
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ScrollViewReader { proxy in
      if items.isEmpty {
        AgentEmptyConversationView(onPromptSuggestion: onPromptSuggestion)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(items) { item in
              AgentConversationRowView(item: item, onOpenArtifact: onOpenArtifact)
                .id(item.id)
            }
          }
          .frame(maxWidth: 820)
          .padding(.horizontal, 34)
          .padding(.vertical, 24)
          .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
        .onChange(of: items.count) { _, _ in
          guard let lastID = items.last?.id else { return }
          if reduceMotion {
            proxy.scrollTo(lastID, anchor: .bottom)
          } else {
            withAnimation(.easeOut(duration: 0.18)) {
              proxy.scrollTo(lastID, anchor: .bottom)
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
