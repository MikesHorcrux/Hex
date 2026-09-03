import SwiftUI

struct HexExternalComputerPermissionsView: View {
  @Environment(\.openURL) private var openURL

  var body: some View {
    Label("Structured browser automation through Playwright", systemImage: "globe")
    Text(
      "Playwright controls browsers through its own local protocol; it does not need macOS Accessibility."
    )
    .font(.caption)
    .foregroundStyle(.secondary)

    Label("Screen observation through Peekaboo", systemImage: "eye")
    Text("Screen Recording belongs to the Peekaboo executable and is not yet verified by Hex.")
      .font(.caption)
      .foregroundStyle(.secondary)
    Button("Open Screen Recording Settings") {
      openPrivacySettings("Privacy_ScreenCapture")
    }

    Label("Protected folders", systemImage: "internaldrive")
    Text("Full Disk Access is a separate macOS grant and is not verified by this check.")
      .font(.caption)
      .foregroundStyle(.secondary)
    Button("Open Full Disk Access Settings") {
      openPrivacySettings("Privacy_AllFiles")
    }
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
