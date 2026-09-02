import SwiftUI

struct HexComputerAccessView: View {
  @Environment(\.openURL) private var openURL

  var body: some View {
    Section {
      Label("App discovery and activation", systemImage: "macwindow")
      Label("Semantic control through macOS Accessibility", systemImage: "accessibility")
      Label("Structured browser automation through Playwright", systemImage: "globe")
      Label("Screen observation and native interaction through Peekaboo", systemImage: "eye")

      Text(
        "Hex asks for approval before every new capability scope. Screen Recording and "
          + "Accessibility remain macOS-controlled permissions; enabling an integration does not "
          + "grant either permission automatically."
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
