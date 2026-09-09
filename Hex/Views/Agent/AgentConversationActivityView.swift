import HexCore
import SwiftUI

struct AgentConversationActivityView: View {
  let items: [ConversationItem]
  let contentWidth: CGFloat
  let onOpenArtifact: (ArtifactReference) -> Void
  @State private var isExpanded = false

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: 12) {
        ForEach(items) { item in
          AgentConversationRowView(
            item: item, bubbleWidth: max(1, contentWidth - 56),
            onOpenArtifact: onOpenArtifact)
        }
      }
      .padding(.top, 10)
    } label: {
      Text("Tool activity")
        .font(.callout)
        .foregroundStyle(HexBrandPalette.mutedInk)
    }
    .tint(HexBrandPalette.mutedInk)
    .padding(.leading, 42)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("conversationActivity-\(items.first?.id.uuidString ?? "empty")")
  }
}
