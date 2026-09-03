import Observation
import SwiftUI

struct HexAccessibilityPermissionView: View {
  @Bindable var model: HexAccessibilityPermissionModel

  @Environment(\.openURL) private var openURL

  var body: some View {
    switch model.state {
    case .unchecked:
      Label("Accessibility has not been checked", systemImage: "questionmark.circle")
        .foregroundStyle(.secondary)
      refreshButton(title: "Check Accessibility")

    case .checking:
      ProgressView("Checking Accessibility in Hex Agent…")

    case .trusted:
      Label("Accessibility granted to Hex Agent", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
      refreshButton(title: "Verify Again")

    case .notTrusted:
      Label("Accessibility not granted to Hex Agent", systemImage: "xmark.circle.fill")
        .foregroundStyle(.orange)
      Text(
        "Request access to add the actual resident agent to macOS Privacy & Security. Look for Hex or Hex Agent."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      Button("Request Accessibility") {
        Task {
          await model.request()
        }
      }
      .accessibilityIdentifier("requestAccessibilityButton")

    case .requestSent:
      Label("Accessibility request sent", systemImage: "clock.badge.checkmark")
        .foregroundStyle(.orange)
      Text(
        "macOS has not been rechecked yet. Enable Hex or Hex Agent in Accessibility, return to Hex, then verify again."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      Button("Open Accessibility Settings") {
        openAccessibilitySettings()
      }
      refreshButton(title: "Verify Accessibility")

    case .gatewayUnavailable:
      Label("Hex Agent is registered but unreachable", systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      Text("No permission result was inferred. Fix or restart the resident agent, then retry.")
        .font(.caption)
        .foregroundStyle(.secondary)
      refreshButton(title: "Retry Accessibility Check")

    case .failed(let message):
      Label("Accessibility check failed", systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      Text(message)
        .font(.caption)
        .foregroundStyle(.secondary)
      refreshButton(title: "Retry Accessibility Check")
    }
  }

  private func refreshButton(title: String) -> some View {
    Button(title) {
      Task {
        await model.refresh()
      }
    }
  }

  private func openAccessibilitySettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
      )
    else {
      return
    }
    openURL(url)
  }
}
