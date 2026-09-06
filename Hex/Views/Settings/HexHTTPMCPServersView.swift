import Observation
import SwiftUI

struct HexHTTPMCPServersView: View {
  @Bindable var model: HexResidentSetupModel
  @State private var serverID = ""
  @State private var endpoint = ""

  var body: some View {
    Section {
      if model.httpMCPServers.isEmpty {
        Label(
          "No extra tool servers connected",
          systemImage: "point.3.connected.trianglepath.dotted"
        )
        .foregroundStyle(.secondary)
      }

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

      TextField("Connection name (for example, local_docs)", text: $serverID)
        .accessibilityIdentifier("residentHTTPMCPServerIDField")
      TextField("Secure server address", text: $endpoint)
        .accessibilityIdentifier("residentHTTPMCPEndpointField")

      HStack {
        Spacer()
        Button("Add Server") {
          if model.addHTTPMCPServer(serverID: serverID, endpoint: endpoint) {
            serverID = ""
            endpoint = ""
          }
        }
        .buttonStyle(.hexSecondaryAction)
        .disabled(serverID.isEmpty || endpoint.isEmpty)
      }

      Text(
        "For advanced integrations. Hex accepts secure internet addresses and local addresses on this Mac. Sign-in headers are not stored here."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    } header: {
      Text("Extra tool servers")
    }
  }
}
