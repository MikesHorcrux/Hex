import AppKit
import Observation
import SwiftUI

struct HexExternalComputerPermissionsView: View {
  @Bindable var model: HexResidentSetupModel
  @Environment(\.openURL) private var openURL

  var body: some View {
    Label("Browser control", systemImage: "globe")
    Text("Browser control does not need a separate macOS privacy permission.")
      .font(.caption)
      .foregroundStyle(.secondary)

    Label("Screen control", systemImage: "eye")
    screenControlStatus
    Button(
      model.screenControlPermissionsGranted == true ? "Verify Again" : "Allow Screen Control"
    ) {
      model.requestScreenControlPermissions()
    }
    .disabled(model.isRequestingScreenControl)

    Label("Protected folders", systemImage: "internaldrive")
    Text(
      "macOS requires you to add Hex Agent manually. Reveal it, then add it in Full Disk Access."
    )
    .font(.caption)
    .foregroundStyle(.secondary)
    Button("Reveal Hex Agent") {
      revealResidentAgent()
    }
    Button("Open Full Disk Access Settings") {
      openPrivacySettings("Privacy_AllFiles")
    }
  }

  @ViewBuilder
  private var screenControlStatus: some View {
    if model.isRequestingScreenControl {
      Label("Checking screen control…", systemImage: "hourglass")
        .foregroundStyle(.secondary)
    } else if model.screenControlPermissionsGranted == true {
      Label("Screen control permissions granted", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
    } else if model.screenControlPermissionsGranted == false {
      Text("Screen control still needs one or more macOS privacy permissions.")
        .font(.caption)
        .foregroundStyle(.secondary)
    } else {
      Text(
        "Hex will install screen control if needed, then request and verify its Mac permissions."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private func revealResidentAgent() {
    let url = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Resources/HexGateway.app", isDirectory: true)
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  private func openPrivacySettings(_ anchor: String) {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
      )
    else {
      return
    }
    openURL(url)
  }
}
