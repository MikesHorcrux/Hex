import SwiftUI
import UniformTypeIdentifiers

struct HexMLXBackendSettingsView: View {
  @Bindable var model: HexInferenceBackendSettingsModel
  @State private var isSelectingDirectory = false

  var body: some View {
    Section {
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
        Button("Choose Folder") {
          isSelectingDirectory = true
        }
      }
      .accessibilityElement(children: .contain)

      TextField("Context window (optional)", text: $model.mlxContextWindow)
      TextField("Maximum output tokens", text: $model.mlxMaximumOutputTokens)
        .accessibilityIdentifier("inferenceMLXOutputTokensField")

      Toggle("Enable tool calling", isOn: $model.mlxSupportsToolCalling)
      Toggle("Enable parallel tool calling", isOn: $model.mlxSupportsParallelToolCalling)
        .disabled(!model.mlxSupportsToolCalling)
    } header: {
      Text("Local MLX model")
    } footer: {
      Text(
        "Choose an existing local model directory. Hex validates it on save and never downloads model files."
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
}
