import SwiftUI

struct AgentWorkspaceHeaderView: View {
  let conversationTitle: String
  let activity: String
  let connectionState: AgentConnectionState
  let runState: AgentRunState

  var body: some View {
    HStack(spacing: 14) {
      HexAppIconView(size: 48)

      VStack(alignment: .leading, spacing: 4) {
        Text("HEX · PERSONAL MAC AGENT")
          .font(.caption2.weight(.bold))
          .tracking(1.4)
          .foregroundStyle(HexBrandPalette.accentInk)

        Text(conversationTitle)
          .font(.title3.weight(.bold))
          .foregroundStyle(HexBrandPalette.ink)
          .lineLimit(1)
      }

      Spacer(minLength: 24)

      VStack(alignment: .trailing, spacing: 5) {
        HStack(spacing: 7) {
          Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
          Text(statusLabel)
            .font(.caption.weight(.semibold))
            .foregroundStyle(HexBrandPalette.ink)

          if runState == .starting || runState == .running || connectionState == .connecting {
            ProgressView()
              .controlSize(.mini)
              .tint(HexBrandPalette.coral)
              .accessibilityLabel("Hex is working")
          }
        }

        Text(activity)
          .font(.caption)
          .foregroundStyle(HexBrandPalette.mutedInk)
          .lineLimit(1)
          .help(activity)
      }
      .frame(maxWidth: 340, alignment: .trailing)
    }
    .padding(.horizontal, 28)
    .padding(.vertical, 15)
    .background(HexBrandPalette.raisedSurface.opacity(0.94))
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(HexBrandPalette.hairline)
        .frame(height: 1)
    }
    .accessibilityElement(children: .contain)
  }

  private var statusLabel: String {
    guard connectionState == .connected else {
      return connectionState.label
    }
    return runState.label
  }

  private var statusColor: Color {
    switch connectionState {
    case .disconnected:
      HexBrandPalette.mutedInk
    case .connecting:
      HexBrandPalette.apricot
    case .connected:
      switch runState {
      case .failed, .cancelled:
        HexBrandPalette.coral
      case .starting, .running, .waitingForAuthorization, .cancelling:
        HexBrandPalette.apricot
      case .idle, .completed:
        HexBrandPalette.successInk
      }
    }
  }
}
