import HexMCP
import Observation
import SwiftUI

struct HexMCPIntegrationsView: View {
  @Bindable var model: HexResidentSetupModel

  var body: some View {
    Section {
      Toggle("Use Playwright browser tools", isOn: $model.playwrightMCPEnabled)
        .accessibilityIdentifier("residentPlaywrightMCPToggle")

      LabeledContent("Playwright \(MCPManagedToolLayout.playwrightVersion)") {
        availabilityLabel(model.playwrightAvailability)
      }

      Text(
        "Microsoft Playwright runs in an isolated browser profile. Hex owns the agent loop and "
          + "routes every MCP action through Hex authorization. Browser artifacts are bounded "
          + "to 50 MB."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Divider()

      Toggle("Use Peekaboo Mac tools", isOn: $model.peekabooMCPEnabled)
        .accessibilityIdentifier("residentPeekabooMCPToggle")

      LabeledContent("Peekaboo \(MCPManagedToolLayout.peekabooVersion)") {
        availabilityLabel(model.peekabooAvailability)
      }

      Text(
        "Peekaboo supplies screen observation and native Mac actions. Its separate agent mode is "
          + "not used; every tool remains routed through Hex authorization."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Divider()

      Toggle("Use Xcode MCP tools", isOn: $model.xcodeMCPEnabled)
        .accessibilityIdentifier("residentXcodeMCPToggle")

      Text(
        "When Xcode is open, Hex discovers its MCP tools through Xcode's local stdio bridge. "
          + "Each bridge starts lazily when an agent run needs it."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    } header: {
      Text("Agent Tools")
    }
  }

  @ViewBuilder
  private func availabilityLabel(_ availability: MCPManagedToolAvailability) -> some View {
    switch availability {
    case .ready:
      Label("Installed", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
    case .unavailable:
      Label("Missing", systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
    }
  }
}
