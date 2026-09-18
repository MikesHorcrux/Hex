import SwiftUI
import UniformTypeIdentifiers

struct HexMLXBackendSettingsView: View {
  @Bindable var model: HexInferenceBackendSettingsModel
  let showsAdvancedConfiguration: Bool
  @State private var isSelectingDirectory = false

  var body: some View {
    Section {
      if model.isInstallingLocalModel {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("Downloading your private model…")
            Spacer()
            Text(downloadPercentage)
              .monospacedDigit()
              .foregroundStyle(.secondary)
          }
          ProgressView(value: model.localModelDownloadProgress ?? 0)
            .tint(HexBrandPalette.coral)
          Button("Cancel Download", action: model.cancelSave)
        }
      } else if model.mlxDirectory != nil {
        Label("Local model folder selected", systemImage: "folder.fill")
          .foregroundStyle(HexBrandPalette.successInk)
      } else {
        Label("Private after setup", systemImage: "lock.macwindow")
        Text("Hex will download a compatible model when you save and keep its work on this Mac.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if showsAdvancedConfiguration {
        DisclosureGroup("Advanced") {
          TextField("Model identifier", text: $model.mlxModelID)
            .accessibilityIdentifier("inferenceMLXModelField")

          TextField("Display name", text: $model.mlxDisplayName)
            .accessibilityIdentifier("inferenceMLXDisplayNameField")

          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(model.mlxDirectoryDisplayName)
              .lineLimit(2)
              .truncationMode(.middle)
              .foregroundStyle(model.mlxDirectory == nil ? .secondary : .primary)
            Spacer(minLength: 10)
            Button("Use Existing Model") {
              isSelectingDirectory = true
            }
          }
          .accessibilityElement(children: .contain)

          TextField("Context limit (optional)", text: $model.mlxContextWindow)
          TextField("Maximum answer length", text: $model.mlxMaximumOutputTokens)
            .accessibilityIdentifier("inferenceMLXOutputTokensField")

          Toggle("Allow tool use", isOn: $model.mlxSupportsToolCalling)
          Toggle("Allow parallel tool use", isOn: $model.mlxSupportsParallelToolCalling)
            .disabled(!model.mlxSupportsToolCalling)
        }
        .disabled(model.isSaving || model.isLoading)
      }
    } header: {
      Text("On this Mac")
    } footer: {
      Text(
        model.mlxDirectory == nil
          ? "The first setup can take a while and needs several gigabytes of free space."
          : "Model processing stays on this Mac."
      )
    }
    .fileImporter(
      isPresented: $isSelectingDirectory,
      allowedContentTypes: [.folder],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        if let url = urls.first {
          model.chooseMLXDirectory(url)
        }
      case .failure:
        model.errorMessageForFileSelectionFailure()
      }
    }
  }

  private var downloadPercentage: String {
    (model.localModelDownloadProgress ?? 0).formatted(.percent.precision(.fractionLength(0)))
  }
}

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
