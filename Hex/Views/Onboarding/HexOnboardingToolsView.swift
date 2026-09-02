import Observation
import SwiftUI

struct HexOnboardingToolsView: View {
  @Bindable var model: HexResidentSetupModel

  var body: some View {
    Form {
      Section {
        Text("Start with the integrations you trust. Additional HTTP MCP servers live in Settings.")
          .foregroundStyle(.secondary)
      }
      HexMCPIntegrationsView(model: model)
    }
    .formStyle(.grouped)
  }
}
