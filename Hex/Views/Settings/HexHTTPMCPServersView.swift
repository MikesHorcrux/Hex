import Observation
import SwiftUI

struct HexHTTPMCPServersView: View {
  @Bindable var model: HexResidentSetupModel
  @State private var serverID = ""
  @State private var endpoint = ""
  @State private var bearerToken = ""

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
        HexHTTPMCPServerRowView(model: model, server: server)
      }

      TextField("Connection name (for example, local_docs)", text: $serverID)
        .accessibilityIdentifier("residentHTTPMCPServerIDField")
      TextField("Secure server address", text: $endpoint)
        .accessibilityIdentifier("residentHTTPMCPEndpointField")
      SecureField("Bearer token (optional)", text: $bearerToken)
        .accessibilityIdentifier("residentHTTPMCPBearerTokenField")

      HStack {
        Spacer()
        Button("Add Server") {
          if model.addHTTPMCPServer(
            serverID: serverID, endpoint: endpoint, bearerToken: bearerToken)
          {
            serverID = ""
            endpoint = ""
            bearerToken = ""
          }
        }
        .buttonStyle(.hexSecondaryAction)
        .disabled(serverID.isEmpty || endpoint.isEmpty)
      }

      Text(
        "Use an HTTPS or local HTTP MCP address. Tokens are stored in Keychain when you save. After saving, use Check connection above to discover tools."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    } header: {
      Text("HTTP tool servers")
    }
    .disabled(!model.canEditMCPServers)
  }
}
