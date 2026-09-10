import HexCore
import SwiftUI

struct AgentConversationRowView: View {
  let item: ConversationItem
  var bubbleWidth: CGFloat?
  var onOpenArtifact: (ArtifactReference) -> Void = { _ in }
  var collapsesTools = false

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 10) {
        messageContent
        ForEach(item.artifacts, id: \.id) { artifact in
          Button {
            onOpenArtifact(artifact)
          } label: {
            Label(
              "View \(artifact.isComplete ? "saved" : "partial") output · "
                + ByteCountFormatter.string(fromByteCount: artifact.byteCount, countStyle: .file),
              systemImage: "doc.text.magnifyingglass")
          }
          .buttonStyle(.bordered)
          .help("Read the complete saved output")
        }
      }
      .foregroundStyle(HexBrandPalette.ink)
      .padding(.horizontal, item.role == .user ? 16 : 0)
      .padding(.vertical, item.role == .user ? 12 : 4)
      // Keep viewport-derived widths: unconstrained probes retypeset every older long answer.
      .frame(
        width: bubbleWidth.map { min($0, item.role == .user ? 560 : 720) }, alignment: .leading
      )
      .frame(maxWidth: bubbleWidth == nil ? 720 : nil, alignment: .leading)
      .background(
        item.role == .user ? HexBrandPalette.softCoral.opacity(0.65) : .clear,
        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    .frame(maxWidth: .infinity, alignment: item.role == .user ? .trailing : .leading)
    .padding(.vertical, item.role == .tool || item.role == .event ? 2 : 8)
    // Contain preserves links and artifact actions as individually navigable children.
    .accessibilityElement(children: .contain)
    .accessibilityLabel(item.role.label)
    .accessibilityIdentifier("conversationMessage-\(item.id)")
  }

  @ViewBuilder
  private var messageContent: some View {
    if item.role == .event {
      Text((try? AttributedString(markdown: item.text)) ?? AttributedString(item.text))
        .font(.callout).foregroundStyle(HexBrandPalette.mutedInk)
        .textSelection(.enabled)
    } else if item.role == .tool {
      if collapsesTools {
        DisclosureGroup("Tool activity") { toolContent }
      } else {
        toolContent
      }
    } else if item.isStreaming {
      AgentStreamingTextView(text: item.text.isEmpty ? "…" : item.text).equatable()
    } else {
      MarkdownMessageView(markdown: item.text.isEmpty ? "…" : item.text).equatable()
    }
  }

  private var toolContent: some View {
    Text(item.text).font(.system(.callout, design: .monospaced))
      .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
  }
}
