import HexCore
import SwiftUI

struct AgentConversationRowView: View {
  let item: ConversationItem
  var bubbleWidth: CGFloat?
  var onOpenArtifact: (ArtifactReference) -> Void = { _ in }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      if item.role == .user {
        Spacer(minLength: 72)
      } else {
        avatar
      }

      VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: 7) {
          Text(item.role.label)
            .font(.caption.weight(.bold))
            .foregroundStyle(HexBrandPalette.ink)
          Text(item.timestamp, style: .time)
            .font(.caption2)
            .foregroundStyle(HexBrandPalette.mutedInk)
          if item.isStreaming {
            ProgressView()
              .controlSize(.mini)
              .tint(HexBrandPalette.coral)
              .accessibilityLabel("Hex is responding")
          }
        }

        if item.role == .event {
          Text(item.text.isEmpty ? "…" : item.text)
            .font(.callout)
            .foregroundStyle(HexBrandPalette.mutedInk)
            .textSelection(.enabled)
        } else if item.role == .tool {
          Text(item.text)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
        } else if item.isStreaming {
          AgentStreamingTextView(text: item.text.isEmpty ? "…" : item.text)
            .equatable()
        } else {
          MarkdownMessageView(markdown: item.text.isEmpty ? "…" : item.text)
            .equatable()
        }
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
          .help("Read the saved output without adding the whole file to the conversation")
        }
      }
      .padding(.horizontal, 15)
      .padding(.vertical, 12)
      // A fixed, viewport-derived width avoids repeated zero/infinite-width typesetting probes
      // through every older multi-screen answer when the current row grows.
      .frame(
        width: bubbleWidth.map { min($0, item.role == .user ? 620 : 720) }, alignment: .leading
      )
      .frame(
        maxWidth: bubbleWidth == nil ? (item.role == .user ? 620 : 720) : nil, alignment: .leading
      )
      .hexSurface(
        cornerRadius: 18,
        fill: bubbleColor,
        border: bubbleBorderColor,
        shadowRadius: item.role == .event ? 0 : 5
      )

      if item.role == .user {
        avatar
      } else {
        Spacer(minLength: 72)
      }
    }
    .padding(.vertical, 3)
  }

  @ViewBuilder
  private var avatar: some View {
    if item.role == .assistant {
      HexAppIconView(size: 34)
    } else {
      Image(systemName: icon)
        .font(.callout.weight(.semibold))
        .foregroundStyle(iconColor)
        .frame(width: 32, height: 32)
        .background(iconColor.opacity(0.12), in: Circle())
        .overlay {
          Circle()
            .strokeBorder(iconColor.opacity(0.16), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
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
      HexBrandPalette.coral
    case .assistant:
      HexBrandPalette.deepPlum
    case .tool:
      HexBrandPalette.apricot
    case .event:
      HexBrandPalette.mutedInk
    }
  }

  private var bubbleColor: Color {
    switch item.role {
    case .user:
      HexBrandPalette.softCoral
    case .assistant:
      HexBrandPalette.raisedSurface
    case .tool:
      HexBrandPalette.softApricot.opacity(0.82)
    case .event:
      HexBrandPalette.surface.opacity(0.78)
    }
  }

  private var bubbleBorderColor: Color {
    switch item.role {
    case .user:
      HexBrandPalette.coral.opacity(0.24)
    case .assistant, .event:
      HexBrandPalette.hairline
    case .tool:
      HexBrandPalette.apricot.opacity(0.32)
    }
  }
}
