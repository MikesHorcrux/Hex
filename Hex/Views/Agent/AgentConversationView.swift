import HexCore
import SwiftUI

struct AgentConversationView: View {
  let items: [ConversationItem]
  let onPromptSuggestion: (String) -> Void
  var onOpenArtifact: (ArtifactReference) -> Void = { _ in }
  var hasEarlierMessages = false
  var showsLatestButton = false
  var isLoadingHistory = false
  var onEarlierMessages: () -> Void = {}
  var onLatestMessages: () -> Void = {}
  var collapsesTools = false
  @State private var followsLatest = true

  var body: some View {
    GeometryReader { geometry in
      let contentWidth = max(1, min(820, geometry.size.width - 68))
      ScrollViewReader { proxy in
        if items.isEmpty {
          AgentEmptyConversationView(onPromptSuggestion: onPromptSuggestion)
        } else {
          ScrollView {
            // Multi-screen messages need measured heights before scrolling. Lazy stacks and native
            // list estimates both moved the viewport as old answers were measured offscreen.
            VStack(alignment: .leading, spacing: 10) {
              if hasEarlierMessages {
                Button("Load earlier messages") {
                  followsLatest = false
                  onEarlierMessages()
                }
                .disabled(isLoadingHistory)
                .accessibilityIdentifier("loadEarlierMessages")
              }
              if showsLatestButton {
                Button("Jump to latest", action: onLatestMessages)
                  .disabled(isLoadingHistory)
                  .accessibilityIdentifier("jumpToLatestMessages")
              }
              ForEach(items) { item in
                AgentConversationRowView(
                  item: item, bubbleWidth: max(1, contentWidth - 130),
                  onOpenArtifact: onOpenArtifact, collapsesTools: collapsesTools
                )
                .id(item.id)
              }
            }
            .frame(width: contentWidth)
            .padding(.horizontal, 34)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
          }
          .scrollIndicators(.automatic)
          .defaultScrollAnchor(.bottom, for: .initialOffset)
          .defaultScrollAnchor(
            followsLatest && !showsLatestButton ? .bottom : nil, for: .sizeChanges
          )
          .onScrollPhaseChange { _, phase, context in
            if phase == .interacting {
              followsLatest = false
            } else if phase == .idle {
              let geometry = context.geometry
              followsLatest =
                geometry.contentOffset.y + geometry.containerSize.height
                >= geometry.contentSize.height - 48
            }
          }
          .onChange(of: items.last?.id) { _, lastID in
            if let lastID, !showsLatestButton {
              followsLatest = true
              proxy.scrollTo(lastID, anchor: .bottom)
            }
          }
          .onChange(of: items.first?.id) { _, firstID in
            if showsLatestButton, let firstID {
              followsLatest = false
              proxy.scrollTo(firstID, anchor: .top)
            }
          }
          .onChange(of: showsLatestButton) { _, showsEarlier in
            if !showsEarlier, let lastID = items.last?.id {
              followsLatest = true
              proxy.scrollTo(lastID, anchor: .bottom)
            }
          }
          .onChange(of: items.last?.isStreaming) { _, isStreaming in
            // Final Markdown can change the row's height after the last token. Bring that settled
            // answer into view once; do not animate or scroll on every incoming character.
            if isStreaming == false, followsLatest, !showsLatestButton, let lastID = items.last?.id
            {
              proxy.scrollTo(lastID, anchor: .bottom)
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
