import SwiftUI

struct HexComputerAccessView: View {
  @Environment(\.openURL) private var openURL

  var body: some View {
    Section {
      Label("App discovery and activation", systemImage: "macwindow")
      Label("Semantic control through macOS Accessibility", systemImage: "accessibility")
      Label("Public HTTPS search, fetch, and browser opening", systemImage: "globe")

      Text(
        "Hex asks for approval before every new capability scope. Accessibility permission is "
          + "requested only after you approve a Mac-control action. The process running the agent "
          + "(normally HexGateway) must be enabled in Privacy & Security."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      Button("Open Accessibility Settings") {
        guard
          let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
          )
        else {
          return
        }
        openURL(url)
      }
    } header: {
      Text("Computer & Web")
    }
  }
}
