import HexMCP
import Observation
import SwiftUI

struct HexMCPIntegrationsView: View {
  @Bindable var model: HexResidentSetupModel

  var body: some View {
    Section {
      Toggle(
        "Browser control",
        isOn: Binding(
          get: { model.playwrightMCPEnabled },
          set: { model.setPlaywrightEnabled($0) }
        )
      )
      .accessibilityIdentifier("residentPlaywrightMCPToggle")
      .disabled(model.isInstallingPlaywright)

      if model.isInstallingPlaywright {
        Label("Downloading browser control…", systemImage: "arrow.down.circle")
          .foregroundStyle(.secondary)
      } else if model.playwrightAvailability == .ready {
        Label("Browser control is ready", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
      }

      Text(
        "Hex uses an isolated browser profile. If browser control is not installed, Hex downloads "
          + "and verifies it automatically."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Divider()

      Toggle(
        "Screen control",
        isOn: Binding(
          get: { model.peekabooMCPEnabled },
          set: { model.setPeekabooEnabled($0) }
        )
      )
      .accessibilityIdentifier("residentPeekabooMCPToggle")
      .disabled(model.isInstallingPeekaboo)

      if model.isInstallingPeekaboo {
        Label("Downloading screen control…", systemImage: "arrow.down.circle")
          .foregroundStyle(.secondary)
      } else if model.peekabooAvailability == .ready {
        Label("Screen control is ready", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
      }

      Text(
        "Screen control lets Hex observe and operate Mac apps. Hex installs its private component "
          + "automatically and still asks before protected actions."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Divider()

      Toggle("Xcode control", isOn: $model.xcodeMCPEnabled)
        .accessibilityIdentifier("residentXcodeMCPToggle")

      Text(
        "When Xcode is open, Hex can use its built-in automation connection."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    } header: {
      Text("Agent Tools")
    }
  }

}
