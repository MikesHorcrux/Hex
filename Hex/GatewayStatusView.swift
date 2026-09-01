import SwiftUI

struct GatewayStatusView: View {
  let connectionState: AgentWorkspaceModel.ConnectionState
  let runState: AgentWorkspaceModel.RunState
  let runSummary: String
  let onConnect: () -> Void
  let onDisconnect: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      HStack(spacing: 7) {
        Circle()
          .fill(connectionColor)
          .frame(width: 8, height: 8)
        Text(connectionState.label)
          .font(.subheadline.weight(.medium))
      }

      Divider()
        .frame(height: 18)

      Label(runSummary, systemImage: runIcon)
        .font(.subheadline)
        .foregroundStyle(runState == .failed ? .red : .secondary)
        .lineLimit(1)

      Spacer()

      if connectionState == .connecting {
        ProgressView()
          .controlSize(.small)
      } else if connectionState == .connected {
        Button("Disconnect", action: onDisconnect)
          .buttonStyle(.link)
          .controlSize(.small)
      } else {
        Button("Connect", action: onConnect)
          .buttonStyle(.link)
          .controlSize(.small)
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
    .background(.thinMaterial)
  }

  private var connectionColor: Color {
    switch connectionState {
    case .connected:
      .green
    case .connecting:
      .orange
    case .disconnected:
      .secondary
    }
  }

  private var runIcon: String {
    switch runState {
    case .idle, .completed:
      "checkmark.circle"
    case .starting, .running:
      "circle.dotted"
    case .waitingForAuthorization:
      "lock.shield"
    case .cancelling, .cancelled:
      "stop.circle"
    case .failed:
      "exclamationmark.triangle"
    }
  }
}
