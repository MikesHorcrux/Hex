import SwiftUI

struct AgentSidebarStatusView: View {
  let connectionState: AgentConnectionState
  let runSummary: String

  var body: some View {
    HStack(spacing: 10) {
      ZStack {
        Circle()
          .fill(statusColor.opacity(0.18))
          .frame(width: 28, height: 28)
        Circle()
          .fill(statusColor)
          .frame(width: 9, height: 9)
      }

      VStack(alignment: .leading, spacing: 2) {
        Text(connectionState.label)
          .font(.caption.weight(.bold))
          .foregroundStyle(HexBrandPalette.ink)
        Text(runSummary)
          .font(.caption2)
          .foregroundStyle(HexBrandPalette.mutedInk)
          .lineLimit(1)
      }

      Spacer(minLength: 4)

      if connectionState == .connecting {
        ProgressView()
          .controlSize(.small)
          .tint(HexBrandPalette.coral)
      }
    }
    .padding(11)
    .hexSurface(cornerRadius: 14, fill: HexBrandPalette.raisedSurface, shadowRadius: 4)
    .padding(10)
    .background(HexBrandPalette.sidebarTint)
    .accessibilityElement(children: .combine)
  }

  private var statusColor: Color {
    switch connectionState {
    case .connected:
      HexBrandPalette.successInk
    case .connecting:
      HexBrandPalette.apricot
    case .disconnected:
      HexBrandPalette.mutedInk
    }
  }
}
