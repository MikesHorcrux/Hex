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
  var expandsActivity = false
  @State private var followsLatest = true

  var body: some View {
    GeometryReader { geometry in
      let contentWidth = max(1, min(760, geometry.size.width - 48))
      let segments = AgentConversationSegment.make(items, collapsesTools: collapsesTools)
      ScrollViewReader { proxy in
        if items.isEmpty {
          if isLoadingHistory {
            ProgressView("Loading conversation…")
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            AgentEmptyConversationView(onPromptSuggestion: onPromptSuggestion)
          }
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
              ForEach(segments) { segment in
                Group {
                  if segment.isActivity {
                    AgentConversationActivityView(
                      items: segment.items, contentWidth: contentWidth,
                      onOpenArtifact: onOpenArtifact, expandsActivity: expandsActivity)
                  } else if let item = segment.items.first {
                    AgentConversationRowView(
                      item: item, bubbleWidth: max(1, contentWidth - 42),
                      onOpenArtifact: onOpenArtifact)
                  }
                }
                .id(segment.id)
              }
            }
            .frame(width: contentWidth)
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
          }
          .overlay(alignment: .bottom) {
            if !followsLatest && !showsLatestButton {
              Button("Jump to latest", systemImage: "arrow.down") {
                followsLatest = true
                if let id = segments.last?.id { proxy.scrollTo(id, anchor: .bottom) }
              }
              .buttonStyle(.hexSecondaryAction)
              .padding(.bottom, 12)
            }
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
          .onChange(of: items.last?.id) { _, _ in
            if let lastID = segments.last?.id, followsLatest, !showsLatestButton {
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
            if !showsEarlier, let lastID = segments.last?.id {
              followsLatest = true
              proxy.scrollTo(lastID, anchor: .bottom)
            }
          }
          .onChange(of: items.last?.isStreaming) { _, isStreaming in
            // Final Markdown can change the row's height after the last token. Bring that settled
            // answer into view once; do not animate or scroll on every incoming character.
            if isStreaming == false, followsLatest, !showsLatestButton,
              let lastID = segments.last?.id
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
