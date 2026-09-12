import Foundation
import Testing

@testable import HexCore

@Suite("Resident runtime settings")
struct HexResidentRuntimeSettingsTests {
  @Test
  func roundTripsOnlyNonSecretSettingsWithCurrentSchema() throws {
    let settings = try HexResidentRuntimeSettings(
      modelID: "gpt-test",
      workspaceRoot: URL(fileURLWithPath: "/tmp/hex-workspace"),
      mcpServers: [
        try .xcode(),
        try .playwright(),
        try .peekaboo(),
        try HexResidentMCPServerSettings(
          serverID: "local_docs",
          transport: .streamableHTTP,
          endpointURL: URL(string: "http://127.0.0.1:8765/mcp")
        ),
      ],
      authorizationMode: .fullAccess
    )
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(HexResidentRuntimeSettings.self, from: data)

    #expect(settings == decoded)
    #expect(settings.schemaVersion == HexResidentRuntimeSettings.currentSchemaVersion)
    #expect(decoded.authorizationMode == .fullAccess)
    #expect(!String(decoding: data, as: UTF8.self).contains("apiKey"))
    #expect(
      decoded.mcpServers.map(\.serverID)
        == ["local_docs", "peekaboo", "playwright", "xcode"]
    )
  }

  @Test
  func rejectsNonFileWorkspaceAndUnsupportedSchema() throws {
    guard let nonFileURL = URL(string: "https://example.com/workspace") else {
      Issue.record("Could not prepare a non-file URL fixture.")
      return
    }
    do {
      _ = try HexResidentRuntimeSettings(
        modelID: "gpt-test",
        workspaceRoot: nonFileURL
      )
      Issue.record("Expected a relative workspace URL to be rejected.")
    } catch let error as HexResidentRuntimeSettingsError {
      #expect(error == .invalidWorkspaceRoot)
    }

    let unsupportedVersion = HexResidentRuntimeSettings.currentSchemaVersion + 1
    do {
      _ = try HexResidentRuntimeSettings(
        modelID: "gpt-test",
        workspaceRoot: URL(fileURLWithPath: "/tmp/hex-workspace"),
        schemaVersion: unsupportedVersion
      )
      Issue.record("Expected an unsupported schema version to be rejected.")
    } catch let error as HexResidentRuntimeSettingsError {
      #expect(error == .unsupportedSchemaVersion(unsupportedVersion))
    }
  }

  @Test
  func decodesLegacySchemaWithoutMCPServers() throws {
    let data = Data(
      #"{"schemaVersion":1,"modelID":"gpt-test","workspaceRoot":"file:\/\/\/tmp\/hex-workspace"}"#
        .utf8
    )

    let settings = try JSONDecoder().decode(HexResidentRuntimeSettings.self, from: data)

    #expect(settings.mcpServers.isEmpty)
    #expect(settings.authorizationMode == .askEveryTime)
  }

  @Test
  func rejectsDuplicateAndUnsafeMCPSettings() throws {
    let xcode = try HexResidentMCPServerSettings.xcode()
    #expect(throws: HexResidentRuntimeSettingsError.invalidMCPServers) {
      _ = try HexResidentRuntimeSettings(
        modelID: "gpt-test",
        workspaceRoot: URL(fileURLWithPath: "/tmp/hex-workspace"),
        mcpServers: [xcode, xcode]
      )
    }
    #expect(throws: HexResidentRuntimeSettingsError.invalidMCPServers) {
      _ = try HexResidentMCPServerSettings(
        serverID: "remote",
        transport: .streamableHTTP,
        endpointURL: URL(string: "http://example.com/mcp")
      )
    }
    #expect(throws: HexResidentRuntimeSettingsError.invalidMCPServers) {
      _ = try HexResidentMCPServerSettings(
        serverID: "not-playwright",
        transport: .playwright
      )
    }
    #expect(throws: HexResidentRuntimeSettingsError.invalidMCPServers) {
      _ = try HexResidentMCPServerSettings(
        serverID: "peekaboo",
        transport: .peekaboo,
        endpointURL: URL(string: "http://localhost:8765/mcp")
      )
    }
  }
}
