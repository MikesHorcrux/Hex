import Observation
import SwiftUI

struct HexHTTPMCPServerRowView: View {
  @Bindable var model: HexResidentSetupModel
  let server: HexHTTPMCPServer
  @State private var bearerToken = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Toggle(
          isOn: Binding(
            get: { server.isEnabled },
            set: { model.setHTTPMCPServerEnabled(server.serverID, isEnabled: $0) }
          )
        ) {
          VStack(alignment: .leading, spacing: 2) {
            Text(server.serverID).font(.body.monospaced())
            Text(server.endpointURL.absoluteString)
              .font(.caption).foregroundStyle(.secondary)
              .lineLimit(1).truncationMode(.middle)
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

      Text(credentialStatus)
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        SecureField("New bearer token", text: $bearerToken)
          .accessibilityLabel("New bearer token for \(server.serverID)")
          .accessibilityIdentifier("residentMCPToken_\(server.serverID)")
        Button("Use token") {
          if model.stageHTTPMCPBearerToken(server.serverID, token: bearerToken) {
            bearerToken = ""
          }
        }
        .buttonStyle(.hexSecondaryAction)
        .disabled(bearerToken.isEmpty)
        .accessibilityLabel("Use token for \(server.serverID)")
        if server.requiresBearerToken {
          Button("Remove token", role: .destructive) {
            model.removeHTTPMCPBearerToken(server.serverID)
            bearerToken = ""
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("Remove token for \(server.serverID)")
        }
      }
    }
    .padding(.vertical, 4)
    .disabled(!model.canEditMCPServers)
    .onChange(of: model.saveGeneration) { _, _ in bearerToken = "" }
  }

  private var credentialStatus: String {
    if model.hasPendingBearerTokenChange(server.serverID) {
      if model.isBearerTokenChangeStored(server.serverID) {
        return server.requiresBearerToken
          ? "Token saved in Keychain. Connection changes are awaiting successful application."
          : "Token removed from Keychain. Connection changes are awaiting successful application."
      }
      return server.requiresBearerToken
        ? server.hasStoredBearerToken == true
          ? "Replacement token ready to save. Save to replace the token in Keychain."
          : "Token ready to save. Save to store it in Keychain."
        : "Token removal ready to save. Save to remove the saved token."
    }
    if server.requiresBearerToken {
      return switch server.hasStoredBearerToken {
      case true:
        "Bearer token saved in Keychain."
      case false:
        "This connection requires a token, but it is missing from Keychain. Add a token and save."
      case nil:
        "Keychain status could not be checked. You can replace the token or disable this connection and save."
      }
    }
    return "No bearer token configured."
  }
}
