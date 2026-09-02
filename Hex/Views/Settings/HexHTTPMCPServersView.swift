import Observation
import SwiftUI

struct HexHTTPMCPServersView: View {
  @Bindable var model: HexResidentSetupModel
  @State private var serverID = ""
  @State private var endpoint = ""

  var body: some View {
    Section {
      ForEach(model.httpMCPServers) { server in
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Toggle(
            isOn: Binding(
              get: { server.isEnabled },
              set: { model.setHTTPMCPServerEnabled(server.serverID, isEnabled: $0) }
            )
          ) {
            VStack(alignment: .leading, spacing: 2) {
              Text(server.serverID)
                .font(.body.monospaced())
              Text(server.endpointURL.absoluteString)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
          }

          Button(role: .destructive) {
            model.removeHTTPMCPServer(server.serverID)
          } label: {
            Image(systemName: "trash")
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("Remove \(server.serverID) MCP server")
        }
      }

      TextField("Server ID (for example, local_docs)", text: $serverID)
        .accessibilityIdentifier("residentHTTPMCPServerIDField")
      TextField("https://server.example/mcp or http://localhost:port/mcp", text: $endpoint)
        .accessibilityIdentifier("residentHTTPMCPEndpointField")

      HStack {
        Spacer()
        Button("Add MCP Server") {
          if model.addHTTPMCPServer(serverID: serverID, endpoint: endpoint) {
            serverID = ""
            endpoint = ""
          }
        }
        .disabled(serverID.isEmpty || endpoint.isEmpty)
      }

      Text(
        "Only HTTPS endpoints and loopback HTTP endpoints are accepted. Authentication headers "
          + "are never stored in resident settings."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    } header: {
      Text("Additional MCP Servers")
    }
  }
}
