import Observation
import SwiftUI
import UniformTypeIdentifiers

struct HexResidentConfigurationFormView: View {
  @Bindable var model: HexResidentSetupModel
  @State private var isSelectingWorkspace = false

  var body: some View {
    Section {
      TextField("Model", text: $model.modelID)
        .accessibilityIdentifier("residentModelField")

      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(model.workspaceDisplayName)
          .lineLimit(2)
          .truncationMode(.middle)
          .foregroundStyle(model.workspaceRoot == nil ? .secondary : .primary)

        Spacer(minLength: 10)

        Button("Choose Folder") {
          isSelectingWorkspace = true
        }
        .buttonStyle(.hexSecondaryAction)
      }
      .accessibilityElement(children: .contain)
    } header: {
      Text("Workspace")
    } footer: {
      Text("Hex keeps its built-in coding work inside this folder.")
    }
    .fileImporter(
      isPresented: $isSelectingWorkspace,
      allowedContentTypes: [.folder],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        if let url = urls.first {
          model.chooseWorkspace(url)
        }
      case .failure:
        model.reportWorkspaceSelectionFailure()
      }
    }
  }
}
