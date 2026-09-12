import Foundation
import HexCore
import HexMCP
import HexPersistence
import Testing

@testable import HexGatewayKit

@Suite("Resident optional MCP prerequisites")
struct HexGatewayResidentOptionalMCPTests {
  @Test
  func missingManagedIntegrationsPreserveConfigurationAndEnabledIdentity() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = try await loadConfiguration(
      root: root, servers: [try .peekaboo(), try .playwright()])

    #expect(configuration.modelID == "fixture-model")
    #expect(configuration.mcpClientSessions.map(\.serverID) == ["peekaboo", "playwright"])
    for session in configuration.mcpClientSessions {
      let executor = try MCPManagedToolExecutor(session: session)
      #expect(try await executor.availableTools().isEmpty)
      #expect(await executor.currentState() == .unavailable)
      await executor.stop()
    }
  }

  @Test
  func missingXcodeBridgePreservesConfigurationAndEnabledIdentity() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = try HexGatewayResidentConfiguration(
      environment: [
        "HEX_OPENAI_API_KEY": "fixture-not-a-live-key",
        "HEX_OPENAI_MODEL": "fixture-model",
        "HEX_WORKSPACE_ROOT": root.path,
        "HEX_GATEWAY_DATABASE_URL": root.appendingPathComponent("journal.sqlite").path,
        "HEX_XCODE_MCP_ENABLED": "true",
        "DEVELOPER_DIR": root.appendingPathComponent("Missing-Xcode/Developer").path,
      ])

    #expect(configuration.mcpClientSessions.map(\.serverID) == ["xcode"])
    let executor = try MCPManagedToolExecutor(
      session: #require(configuration.mcpClientSessions.first))
    #expect(try await executor.availableTools().isEmpty)
    #expect(await executor.currentState() == .unavailable)
    await executor.stop()
  }

  @Test
  func disabledMissingManagedIntegrationDoesNotCreateASession() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = try await loadConfiguration(
      root: root, servers: [try .peekaboo(isEnabled: false), try .playwright(isEnabled: false)])
    #expect(configuration.mcpClientSessions.isEmpty)
  }

  @Test
  func malformedServerSettingsRemainRejected() throws {
    let invalidEndpoint = Data(
      #"{"serverID":"docs","transport":"streamableHTTP","endpointURL":"http://remote.example.com/mcp","isEnabled":true}"#
        .utf8)
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(HexResidentMCPServerSettings.self, from: invalidEndpoint)
    }
    #expect(throws: HexResidentRuntimeSettingsError.invalidMCPServers) {
      try HexResidentRuntimeSettings(
        modelID: "fixture-model", workspaceRoot: URL(fileURLWithPath: "/tmp"),
        mcpServers: [try .peekaboo(), try .peekaboo()])
    }
  }

  @Test
  func malformedExplicitXcodeToggleRemainsRejected() throws {
    #expect(
      throws: HexGatewayResidentConfiguration.ConfigurationError.invalidVariable(
        "HEX_XCODE_MCP_ENABLED")
    ) {
      try HexGatewayResidentConfiguration(
        environment: [
          "HEX_OPENAI_API_KEY": "fixture-not-a-live-key",
          "HEX_OPENAI_MODEL": "fixture-model",
          "HEX_WORKSPACE_ROOT": "/tmp",
          "HEX_XCODE_MCP_ENABLED": "sometimes",
        ])
    }
  }

  private func loadConfiguration(
    root: URL, servers: [HexResidentMCPServerSettings]
  ) async throws -> HexGatewayResidentConfiguration {
    let paths = try HexResidentDataPaths(
      settingsURL: root.appendingPathComponent("resident.json"),
      databaseURL: root.appendingPathComponent("journal.sqlite"),
      heartbeatStoreURL: root.appendingPathComponent("heartbeats.json"))
    let settings = try HexResidentRuntimeSettings(
      modelID: "fixture-model", workspaceRoot: root, mcpServers: servers)
    return try await HexGatewayResidentConfiguration.loadPersisted(
      paths: paths, settingsStore: SettingsStore(value: settings), secretStore: SecretStore(),
      inferenceBackendSettingsStore: InferenceSettingsStore())
  }

  private func makeTemporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("HexOptionalMCP-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)])
    return root
  }

  private actor SecretStore: HexSecretStore {
    func exists(_ key: HexSecretKey) async throws -> Bool { key == .openAIAPIKey }
    func secret(for key: HexSecretKey) async throws -> String {
      throw FixtureError.unexpectedSecretRead
    }
    func save(_ secret: String, for key: HexSecretKey) async throws {}
    func delete(_ key: HexSecretKey) async throws {}
  }

  private actor SettingsStore: HexResidentRuntimeSettingsStore {
    let value: HexResidentRuntimeSettings

    init(value: HexResidentRuntimeSettings) { self.value = value }
    func load() async throws -> HexResidentRuntimeSettings? { value }
    func save(_ settings: HexResidentRuntimeSettings) async throws {}
  }

  private actor InferenceSettingsStore: HexInferenceBackendSettingsStore {
    func load() async throws -> HexInferenceBackendSettings? {
      try HexInferenceBackendSettings(openAIModelID: "fixture-model")
    }
    func save(_ settings: HexInferenceBackendSettings) async throws {}
  }

  private enum FixtureError: Error { case unexpectedSecretRead }
}
