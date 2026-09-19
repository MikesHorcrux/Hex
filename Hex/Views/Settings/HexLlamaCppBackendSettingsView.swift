import SwiftUI

struct HexLlamaCppBackendSettingsView: View {
  @Bindable var model: HexInferenceBackendSettingsModel
  let showsAdvancedConfiguration: Bool

  var body: some View {
    Section {
      Label("Prism server connection", systemImage: "server.rack")
        .foregroundStyle(HexBrandPalette.successInk)
      Text("Start Prism llama-server with the Bonsai GGUF, then point Hex at its local URL.")
        .font(.caption)
        .foregroundStyle(.secondary)

      if showsAdvancedConfiguration {
        DisclosureGroup("Configuration") {
          TextField("Model identifier", text: $model.llamaModelID)
            .accessibilityIdentifier("inferenceLlamaModelField")

          TextField("Display name", text: $model.llamaDisplayName)

          TextField("Server URL", text: $model.llamaEndpoint)
            .textContentType(.URL)
            .accessibilityIdentifier("inferenceLlamaEndpointField")

          TextField("Context limit (optional)", text: $model.llamaContextWindow)
          TextField("Maximum answer length", text: $model.llamaMaximumOutputTokens)

          Toggle("Allow tool use", isOn: $model.llamaSupportsToolCalling)
          Toggle("Allow parallel tool use", isOn: $model.llamaSupportsParallelToolCalling)
            .disabled(!model.llamaSupportsToolCalling)
        }
        .disabled(model.isSaving || model.isLoading)
      }
    } header: {
      Text("On this Mac — GGUF")
    } footer: {
      Text("Hex talks to the local server over 127.0.0.1; the model remains on this Mac.")
    }
  }
}
