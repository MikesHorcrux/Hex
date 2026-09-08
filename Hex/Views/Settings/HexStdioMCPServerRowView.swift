import Observation
import SwiftUI

struct HexStdioMCPServerRowView: View {
  @Bindable var model: HexResidentSetupModel
  let server: HexStdioMCPServer

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Toggle(
        isOn: Binding(
          get: { server.isEnabled },
          set: { model.setStdioMCPServerEnabled(server.serverID, isEnabled: $0) }
        )
      ) {
        VStack(alignment: .leading, spacing: 2) {
          Text(server.serverID).font(.body.monospaced())
          Text(server.executableURL.path)
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle)
          Text("\(server.arguments.count) arguments · \(server.workingDirectory.path)")
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle)
        }
      }
      Button(role: .destructive) {
        model.removeStdioMCPServer(server.serverID)
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Remove \(server.serverID) local MCP server")
    }
    .disabled(!model.canEditMCPServers)
  }
}
