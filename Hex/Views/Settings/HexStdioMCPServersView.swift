import Observation
import SwiftUI

struct HexStdioMCPServersView: View {
  @Bindable var model: HexResidentSetupModel
  @State private var serverID = ""
  @State private var executablePath = ""
  @State private var argumentsText = ""
  @State private var workingDirectoryPath = ""

  var body: some View {
    Section {
      ForEach(model.stdioMCPServers) { server in
        HexStdioMCPServerRowView(model: model, server: server)
      }
      TextField("Connection name (for example, local_tools)", text: $serverID)
        .accessibilityIdentifier("residentStdioMCPServerIDField")
      TextField("Executable path (absolute)", text: $executablePath)
        .accessibilityIdentifier("residentStdioMCPExecutableField")
      TextField("Working folder path (absolute)", text: $workingDirectoryPath)
        .accessibilityIdentifier("residentStdioMCPWorkingDirectoryField")
      VStack(alignment: .leading, spacing: 4) {
        Text("Arguments (one per line)").font(.caption).foregroundStyle(.secondary)
        TextEditor(text: $argumentsText)
          .font(.body.monospaced())
          .frame(minHeight: 60, maxHeight: 100)
          .accessibilityLabel("Local MCP server arguments, one per line")
          .accessibilityIdentifier("residentStdioMCPArgumentsField")
      }
      HStack {
        Spacer()
        Button("Add Local Server") {
          if model.addStdioMCPServer(
            serverID: serverID, executablePath: executablePath,
            argumentsText: argumentsText, workingDirectoryPath: workingDirectoryPath
          ) {
            serverID = ""
            executablePath = ""
            argumentsText = ""
            workingDirectoryPath = ""
          }
        }
        .buttonStyle(.hexSecondaryAction)
        .disabled(serverID.isEmpty || executablePath.isEmpty || workingDirectoryPath.isEmpty)
      }
      Text(
        "Hex starts the executable directly using stdio. Arguments are passed literally; do not add shell quotes or put secrets in these fields. Save, then use Check connection above."
      )
      .font(.caption).foregroundStyle(.secondary)
    } header: {
      Text("Local tool servers")
    }
    .disabled(!model.canEditMCPServers)
  }
}
