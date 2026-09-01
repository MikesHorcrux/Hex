import Observation
import SwiftUI

struct HexMenuBarView: View {
  @Bindable var workspace: AgentWorkspaceModel
  @Bindable var gateway: HexResidentGatewayModel
  @Bindable var startAtLogin: HexStartAtLoginModel
  @Environment(\.openWindow) private var openWindow

  let route: HexGatewayRoute
  let onQuitHexUI: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("HEX")
        .font(.system(size: 16, weight: .bold, design: .rounded))
        .tracking(1.5)

      HStack(spacing: 8) {
        Circle()
          .fill(statusColor)
          .frame(width: 9, height: 9)
        Text(statusTitle)
          .font(.headline)
        Spacer(minLength: 8)
        if workspace.connectionState == .connecting || gateway.isUpdating {
          ProgressView()
            .controlSize(.small)
        }
      }

      Text(route.label)
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
      Text(routeStatusDetail)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Divider()

      Button {
        gateway.togglePause()
      } label: {
        Label(
          gateway.pauseButtonTitle,
          systemImage: gateway.status.isPaused ? "play.fill" : "pause.fill"
        )
      }
      .disabled(!gateway.canTogglePause)

      Text(HexResidentGatewayStatus.heartbeatControlDetail)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if let message = gateway.message {
        Text(message)
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }

      Divider()

      HStack {
        Label("Start at login", systemImage: "arrow.clockwise.circle")
        Spacer(minLength: 8)
        Text(startAtLogin.status.label)
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
      }

      if route.kind == .developerInProcess {
        Text("Start at login is unavailable for the in-process developer route.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } else if startAtLogin.isAvailable {
        Button(startAtLogin.buttonTitle) {
          startAtLogin.toggle()
        }
        .disabled(!startAtLogin.canChange)

        if startAtLogin.status == .notFound {
          Text("Pending the bundled gateway helper; no launch service has been registered.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      } else if let readinessMessage = startAtLogin.readinessMessage {
        Text(readinessMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if startAtLogin.isAvailable, let message = startAtLogin.message {
        Text(message)
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }

      Divider()

      Button("Open Hex") {
        openWindow(id: "main")
      }
      .keyboardShortcut(.defaultAction)

      Button("Quit Hex UI", action: onQuitHexUI)

      Text("Closing this window does not stop the resident gateway.")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(12)
    .frame(minWidth: 280)
    .task {
      await gateway.refresh()
      await startAtLogin.refresh()
    }
  }

  private var statusTitle: String {
    switch renderedStatus {
    case .unavailable:
      route.isResident ? "Resident unavailable" : "Developer gateway unavailable"
    case .idle:
      "Idle"
    case .active:
      "Active"
    case .paused:
      "Paused"
    }
  }

  private var routeStatusDetail: String {
    switch renderedStatus {
    case .unavailable:
      route.isResident
        ? "Resident heartbeat status is unavailable. The agent may still be running outside this app process."
        : "The explicitly selected developer gateway is not connected."
    case .idle, .active, .paused:
      route.detail
    }
  }

  private var renderedStatus: HexResidentGatewayStatus {
    gateway.status
  }

  private var statusColor: Color {
    switch renderedStatus {
    case .unavailable:
      .secondary
    case .idle:
      .green
    case .active:
      .orange
    case .paused:
      .purple
    }
  }
}
