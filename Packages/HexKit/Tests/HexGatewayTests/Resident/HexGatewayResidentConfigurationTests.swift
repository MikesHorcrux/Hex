import Foundation
import HexGatewayKit
import Testing

@Suite("Resident gateway configuration")
struct HexGatewayResidentConfigurationTests {
  @Test
  func parsesExplicitEnvironmentWithoutExposingCredentialInDiagnostics() async throws {
    let configuration = try HexGatewayResidentConfiguration(
      environment: [
        "HEX_OPENAI_API_KEY": "sk-test-secret",
        "HEX_OPENAI_MODEL": "gpt-test",
        "HEX_WORKSPACE_ROOT": "/tmp/hex-workspace",
        "HEX_GATEWAY_DATABASE_URL": "/tmp/hex-gateway/journal.sqlite",
        "HEX_HEARTBEAT_STORE_URL": "/tmp/hex-gateway/heartbeats.json",
      ]
    )

    #expect(configuration.machServiceName == HexGatewayServiceIdentity.machServiceName)
    #expect(configuration.modelID == "gpt-test")
    #expect(configuration.workspaceRoot.path == "/tmp/hex-workspace")
    #expect(configuration.databaseURL.path == "/tmp/hex-gateway/journal.sqlite")
    #expect(configuration.heartbeatStoreURL.path == "/tmp/hex-gateway/heartbeats.json")
    #expect(
      try await configuration.makeAuthorizationProvider().authorization().bearerToken
        == "sk-test-secret"
    )

    do {
      _ = try HexGatewayResidentConfiguration(
        machServiceName: HexGatewayServiceIdentity.machServiceName,
        modelID: "gpt-test",
        workspaceRoot: URL(fileURLWithPath: "/tmp/hex-workspace"),
        databaseURL: URL(fileURLWithPath: "/tmp/hex-gateway/journal.sqlite"),
        apiKey: "bad\nsecret"
      )
      Issue.record("Expected a non-printable credential to be rejected.")
    } catch let error as HexGatewayResidentConfiguration.ConfigurationError {
      #expect(error == .invalidVariable("HEX_OPENAI_API_KEY"))
      #expect(!String(describing: error).contains("bad"))
      #expect(!String(describing: error).contains("secret"))
    }
  }
}
