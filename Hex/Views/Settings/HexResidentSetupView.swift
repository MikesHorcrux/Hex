import Observation
import SwiftUI
import UniformTypeIdentifiers

struct HexResidentSetupView: View {
  @Bindable var model: HexResidentSetupModel
  @State private var isSelectingWorkspace = false

  var body: some View {
    Form {
      Section {
        SecureField("OpenAI API key", text: $model.apiKey)
          .textContentType(.password)
          .accessibilityIdentifier("residentAPIKeyField")

        Text("Leave this blank to keep the existing key. Hex never displays the stored key.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } header: {
        Text("Inference")
      }

      Section {
        TextField("Model identifier", text: $model.modelID)
          .accessibilityIdentifier("residentModelField")
      } header: {
        Text("Model")
      }

      Section {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Text(model.workspaceDisplayName)
            .lineLimit(2)
            .truncationMode(.middle)
            .foregroundStyle(model.workspaceRoot == nil ? .secondary : .primary)

          Spacer(minLength: 10)

          Button("Choose Folder") {
            isSelectingWorkspace = true
          }
        }
        .accessibilityElement(children: .contain)
      } header: {
        Text("Workspace")
      }

      HexMCPIntegrationsView(model: model)
      HexHTTPMCPServersView(model: model)

      HexComputerAccessView()

      if let statusMessage = model.statusMessage {
        Text(statusMessage)
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      if let errorMessage = model.errorMessage {
        Text(errorMessage)
          .font(.callout)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack {
        Spacer()
        if model.isSaving {
          ProgressView()
            .controlSize(.small)
        }
        Button("Save") {
          model.save()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!model.canSave)
      }
    }
    .formStyle(.grouped)
    .frame(width: 520)
    .scenePadding()
    .task {
      await model.load()
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
