import Observation
import SwiftUI

struct HexResidentAgentAccessView: View {
  @Bindable var accessibilityPermission: HexAccessibilityPermissionModel
  @Bindable var startAtLogin: HexStartAtLoginModel

  var body: some View {
    HStack(spacing: 10) {
      Label("Always-on Hex Agent", systemImage: "bolt.horizontal.circle")
        .font(.headline)
      Spacer()
      Text(startAtLogin.status.label)
        .font(.caption.weight(.semibold))
        .foregroundStyle(statusTint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(statusTint.opacity(0.12), in: Capsule())
    }

    activationContent

    if let readinessMessage = startAtLogin.readinessMessage {
      HexInlineNoticeView(
        message: readinessMessage,
        systemImage: "exclamationmark.triangle.fill",
        tint: .orange
      )
    }

    if let message = startAtLogin.message {
      HexInlineNoticeView(
        message: message,
        systemImage: "exclamationmark.triangle.fill",
        tint: .orange
      )
    }
  }

  @ViewBuilder
  private var activationContent: some View {
    switch startAtLogin.status {
    case .enabled:
      HexAccessibilityPermissionView(model: accessibilityPermission)
      if accessibilityPermission.state.canRepairByRestartingGateway {
        Button("Restart Hex Agent") {
          Task {
            await startAtLogin.restart()
            guard startAtLogin.status == .enabled, startAtLogin.message == nil else { return }
            await accessibilityPermission.refresh()
          }
        }
        .buttonStyle(.hexPrimaryAction)
        .disabled(!startAtLogin.canRestart)
        .accessibilityIdentifier("restartResidentAgentButton")
        if startAtLogin.isUpdating {
          ProgressView("Restarting resident agent…")
        }
      }

    case .notRegistered, .notFound:
      Label("Start Hex Agent before checking Accessibility", systemImage: "questionmark.circle")
        .foregroundStyle(.secondary)
      Text(
        "This background agent is what controls your Mac when the Hex window is closed, so the permission must belong to it."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      Button("Activate Hex Agent") {
        startAtLogin.toggle()
      }
      .buttonStyle(.hexPrimaryAction)
      .disabled(!startAtLogin.canChange)
      if startAtLogin.isUpdating {
        ProgressView("Activating resident agent…")
      }

    case .requiresApproval:
      Label(
        "Resident agent needs Login Items approval", systemImage: "exclamationmark.triangle.fill"
      )
      .foregroundStyle(.orange)
      Button("Open Login Items Settings") {
        Task {
          await startAtLogin.openLoginItemsSettings()
        }
      }
      .buttonStyle(.hexPrimaryAction)
      refreshButton

    case .unknown:
      ProgressView("Checking resident agent…")

    case .unavailable:
      Label("Resident agent unavailable", systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      refreshButton
    }
  }

  private var refreshButton: some View {
    Button("Refresh Resident Agent") {
      Task {
        await startAtLogin.refresh()
      }
    }
    .buttonStyle(.hexSecondaryAction)
  }

  private var statusTint: Color {
    switch startAtLogin.status {
    case .enabled:
      HexBrandPalette.successInk
    case .requiresApproval:
      .orange
    case .notRegistered, .notFound, .unknown, .unavailable:
      HexBrandPalette.mutedInk
    }
  }
}
