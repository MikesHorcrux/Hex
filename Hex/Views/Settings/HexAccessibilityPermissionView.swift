import Observation
import SwiftUI

struct HexAccessibilityPermissionView: View {
  @Bindable var model: HexAccessibilityPermissionModel

  @Environment(\.openURL) private var openURL

  var body: some View {
    switch model.state {
    case .unchecked:
      Label("Accessibility has not been checked yet", systemImage: "questionmark.circle")
        .foregroundStyle(.secondary)
      refreshButton(title: "Check Accessibility")

    case .checking:
      ProgressView("Checking Accessibility in Hex Agent…")

    case .trusted:
      Label("Accessibility is ready", systemImage: "checkmark.circle.fill")
        .foregroundStyle(HexBrandPalette.successInk)
      refreshButton(title: "Verify Again")

    case .notTrusted:
      Label("Accessibility needs approval", systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      Text(
        "Ask macOS to add the always-on Hex Agent. In Privacy & Security, look for Hex or Hex Agent."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      Button("Request Accessibility") {
        Task {
          await model.request()
        }
      }
      .buttonStyle(.hexPrimaryAction)
      .accessibilityIdentifier("requestAccessibilityButton")
      refreshButton(title: "Verify Accessibility")

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
      .buttonStyle(.hexPrimaryAction)
      refreshButton(title: "Verify Accessibility")

    case .gatewayUnavailable:
      Label("Hex Agent is not responding", systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      Text("No permission result was guessed. Restart the agent, then check again.")
        .font(.caption)
        .foregroundStyle(.secondary)
      refreshButton(title: "Retry Accessibility Check")

    case .gatewayNeedsRestart:
      Label("Hex Agent needs to restart", systemImage: "arrow.clockwise.circle.fill")
        .foregroundStyle(.orange)
      Text(
        "The running agent belongs to a different Hex build. Restart it to load this version, then check Accessibility again."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

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
    .buttonStyle(.hexSecondaryAction)
  }

  private func openAccessibilitySettings() {
    guard
      let url = URL(
        string:
          "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
      )
    else {
      return
    }
    openURL(url)
  }
}
