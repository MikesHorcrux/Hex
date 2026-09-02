import SwiftUI

struct AgentConversationView: View {
  let items: [ConversationItem]

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        if items.isEmpty {
          AgentEmptyConversationView()
        } else {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
              AgentConversationRowView(item: item)
                .id(item.id)
              if item.id != items.last?.id {
                Divider()
              }
            }
          }
          .frame(maxWidth: 840)
          .padding(.horizontal, 28)
          .padding(.vertical, 20)
          .frame(maxWidth: .infinity)
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
}
