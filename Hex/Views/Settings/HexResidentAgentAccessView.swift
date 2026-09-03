import Observation
import SwiftUI

struct HexResidentAgentAccessView: View {
  @Bindable var accessibilityPermission: HexAccessibilityPermissionModel
  @Bindable var startAtLogin: HexStartAtLoginModel

  var body: some View {
    LabeledContent("Resident Hex Agent", value: startAtLogin.status.label)
    activationContent

    if let readinessMessage = startAtLogin.readinessMessage {
      Text(readinessMessage)
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    if let message = startAtLogin.message {
      Text(message)
        .font(.caption)
        .foregroundStyle(.orange)
    }
  }

  @ViewBuilder
  private var activationContent: some View {
    switch startAtLogin.status {
    case .enabled:
      HexAccessibilityPermissionView(model: accessibilityPermission)

    case .notRegistered, .notFound:
      Label("Accessibility has not been checked", systemImage: "questionmark.circle")
        .foregroundStyle(.secondary)
      Text(
        "Activate the resident Hex Agent first. The Accessibility request must come from that background process because it—not this window—controls your Mac."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      Button("Activate Hex Agent") {
        startAtLogin.toggle()
      }
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
  }
}
