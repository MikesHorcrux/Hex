import HexMCP
import Observation
import SwiftUI

struct HexMCPIntegrationsView: View {
  @Bindable var model: HexResidentSetupModel

  var body: some View {
    Section {
      VStack(alignment: .leading, spacing: 7) {
        Toggle(
          isOn: Binding(
            get: { model.playwrightMCPEnabled },
            set: { model.setPlaywrightEnabled($0) }
          )
        ) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Browser control")
            Text("Open pages, click, type, and read the web in a private browser profile.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .accessibilityIdentifier("residentPlaywrightMCPToggle")
        .disabled(model.isInstallingManagedTool)

        if model.isInstallingPlaywright {
          Label("Downloading and checking browser control…", systemImage: "arrow.down.circle")
            .font(.caption)
            .foregroundStyle(HexBrandPalette.accentInk)
        } else if model.playwrightAvailability == .ready {
          Label("Installed", systemImage: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(HexBrandPalette.successInk)
        } else {
          Label("Downloads automatically when enabled", systemImage: "arrow.down.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.vertical, 4)

      VStack(alignment: .leading, spacing: 7) {
        Toggle(
          isOn: Binding(
            get: { model.peekabooMCPEnabled },
            set: { model.setPeekabooEnabled($0) }
          )
        ) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Screen control")
            Text("See and operate Mac apps after you approve the required macOS access.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .accessibilityIdentifier("residentPeekabooMCPToggle")
        .disabled(model.isInstallingManagedTool)

        if model.isInstallingPeekaboo {
          Label("Downloading and checking screen control…", systemImage: "arrow.down.circle")
            .font(.caption)
            .foregroundStyle(HexBrandPalette.accentInk)
        } else if model.peekabooAvailability == .ready {
          Label("Installed", systemImage: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(HexBrandPalette.successInk)
        } else {
          Label("Downloads automatically when enabled", systemImage: "arrow.down.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.vertical, 4)

      Toggle(isOn: $model.xcodeMCPEnabled) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Xcode control")
          Text("Work with the project that is open in Xcode.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .accessibilityIdentifier("residentXcodeMCPToggle")
      .padding(.vertical, 4)
    } header: {
      Text("Built-in tools")
    } footer: {
      Text(
        "Hex installs missing browser and screen-control components for you. macOS permission prompts remain separate and visible."
      )
    }
    .disabled(model.isSaving)
  }
}
