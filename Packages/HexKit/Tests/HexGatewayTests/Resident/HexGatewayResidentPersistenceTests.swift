import Darwin
import Foundation
import HexCore
import HexPersistence
import HexProviders
import Testing

@testable import HexGatewayKit

@Suite("Persisted resident configuration")
struct HexGatewayResidentPersistenceTests {
  @Test
  func loadsSettingsAndDefersSecretReadUntilProviderUse() async throws {
    let root = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: root)
    }
    let paths = try makePaths(in: root)
    let settings = try HexResidentRuntimeSettings(
      modelID: "gpt-persisted",
      workspaceRoot: URL(fileURLWithPath: "/tmp/hex-workspace"),
      mcpServers: [
        try HexResidentMCPServerSettings(
          serverID: "docs",
          transport: .streamableHTTP,
          endpointURL: URL(string: "https://mcp.example.com")
        )
      ],
      authorizationMode: .fullAccess
    )
    let settingsStore = SettingsStore(value: settings)
    let secretStore = SecretStore(value: "sk-persisted-secret")

    let configuration = try await HexGatewayResidentConfiguration.loadPersisted(
      paths: paths,
      settingsStore: settingsStore,
      secretStore: secretStore
    )

    #expect(configuration.modelID == "gpt-persisted")
    #expect(configuration.inferenceBackendSettings.selectedBackend == .openAIResponses)
    #expect(configuration.inferenceBackendSettings.openAI.modelID == "gpt-persisted")
    #expect(configuration.workspaceRoot.path == "/tmp/hex-workspace")
    #expect(configuration.databaseURL == paths.databaseURL)
    #expect(configuration.heartbeatStoreURL == paths.heartbeatStoreURL)
    #expect(configuration.mcpClientSessions.map(\.serverID) == ["docs"])
    #expect(configuration.authorizationMode == .fullAccess)
    #expect(await secretStore.didReadValue() == false)
    #expect(try await configuration.makeCredentialProvider().apiKey() == "sk-persisted-secret")
    #expect(await secretStore.didReadValue())
  }

  @Test
  func rejectsMissingCredentialWithoutTouchingKeyValue() async throws {
    let root = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: root)
    }
    let paths = try makePaths(in: root)
    let settings = try HexResidentRuntimeSettings(
      modelID: "gpt-persisted",
      workspaceRoot: URL(fileURLWithPath: "/tmp/hex-workspace")
    )
    let secretStore = SecretStore(value: nil)

    do {
      _ = try await HexGatewayResidentConfiguration.loadPersisted(
        paths: paths,
        settingsStore: SettingsStore(value: settings),
        secretStore: secretStore
      )
      Issue.record("Expected a missing resident credential to fail loading.")
    } catch let error as HexGatewayResidentConfiguration.ConfigurationError {
      #expect(error == .credentialsUnavailable)
    }
    #expect(await secretStore.didReadValue() == false)
  }

  @Test
  func migratesLegacyModelIntoAbsentInferenceSettingsDocument() async throws {
    let root = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: root)
    }
    let paths = try makePaths(in: root)
    let settings = try HexResidentRuntimeSettings(
      modelID: "legacy-model",
      workspaceRoot: URL(fileURLWithPath: "/tmp/hex-workspace")
    )
    let persistedStore = try JSONHexInferenceBackendSettingsStore(
      fileURL: root.appendingPathComponent("inference-backends.json", isDirectory: false)
    )
    let configuration = try await HexGatewayResidentConfiguration.loadPersisted(
      paths: paths,
      settingsStore: SettingsStore(value: settings),
      secretStore: SecretStore(value: "sk-test"),
      inferenceBackendSettingsStore: persistedStore
    )

    #expect(configuration.inferenceBackendSettings.selectedBackend == .openAIResponses)
    #expect(configuration.inferenceBackendSettings.openAI.modelID == "legacy-model")
    #expect(configuration.modelID == "legacy-model")
    let loadedSettings = try await persistedStore.load()
    #expect(loadedSettings == configuration.inferenceBackendSettings)
  }

  @Test
  func selectedLocalBackendDoesNotRequireAnOpenAICredential() async throws {
    let root = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: root)
    }
    let paths = try makePaths(in: root)
    let settings = try HexResidentRuntimeSettings(
      modelID: "legacy-model",
      workspaceRoot: URL(fileURLWithPath: "/tmp/hex-workspace")
    )
    let inferenceSettings = try HexInferenceBackendSettings(
      selectedBackend: .mlxLocal,
      openAIModelID: "openai-model",
      mlx: HexMLXBackendSettings(
        modelID: "local-model",
        displayName: "Local model",
        directory: URL(fileURLWithPath: "/tmp/hex-model")
      )
    )
    let secretStore = SecretStore(value: nil)
    let configuration = try await HexGatewayResidentConfiguration.loadPersisted(
      paths: paths,
      settingsStore: SettingsStore(value: settings),
      secretStore: secretStore,
      inferenceBackendSettingsStore: BackendSettingsStore(value: inferenceSettings)
    )

    #expect(configuration.inferenceBackendSettings == inferenceSettings)
    #expect(configuration.modelID == "local-model")
    #expect(await secretStore.didCheckExistence() == false)
  }

  @Test
  func identifiesPartialEnvironmentAsAnExplicitOverride() {
    #expect(
      HexGatewayResidentConfiguration.hasEnvironmentOverride(
        in: ["HEX_OPENAI_MODEL": "gpt-test"]
      )
    )
    #expect(!HexGatewayResidentConfiguration.hasEnvironmentOverride(in: [:]))
  }

  @Test
  func rejectsDotPathComponentsAndStandardizedDataDirectories() throws {
    let workspaceRoot = URL(fileURLWithPath: "/tmp/hex-workspace", isDirectory: true)
    let validDatabaseURL = URL(fileURLWithPath: "/tmp/hex-resident/journal.sqlite")

    do {
      _ = try HexGatewayResidentConfiguration(
        machServiceName: "com.test.hex.gateway",
        modelID: "gpt-test",
        workspaceRoot: workspaceRoot,
        databaseURL: URL(fileURLWithPath: "/tmp/.."),
        apiKey: "sk-test"
      )
      Issue.record("Expected a database path containing '..' to be rejected.")
    } catch let error as HexGatewayResidentConfiguration.ConfigurationError {
      #expect(error == .invalidVariable("HEX_GATEWAY_DATABASE_URL"))
    }

    do {
      _ = try HexGatewayResidentConfiguration(
        machServiceName: "com.test.hex.gateway",
        modelID: "gpt-test",
        workspaceRoot: workspaceRoot,
        databaseURL: validDatabaseURL,
        apiKey: "sk-test",
        heartbeatStoreURL: URL(fileURLWithPath: "/tmp/.")
      )
      Issue.record("Expected a heartbeat path containing '.' to be rejected.")
    } catch let error as HexGatewayResidentConfiguration.ConfigurationError {
      #expect(error == .invalidVariable("HEX_HEARTBEAT_STORE_URL"))
    }

    do {
      _ = try HexGatewayResidentConfiguration(
        machServiceName: "com.test.hex.gateway",
        modelID: "gpt-test",
        workspaceRoot: workspaceRoot,
        databaseURL: validDatabaseURL,
        apiKey: "sk-test",
        heartbeatStoreURL: URL(fileURLWithPath: "/")
      )
      Issue.record("Expected a standardized heartbeat directory to be rejected.")
    } catch let error as HexGatewayResidentConfiguration.ConfigurationError {
      #expect(error == .invalidVariable("HEX_HEARTBEAT_STORE_URL"))
    }
  }

  private func makeTemporaryDirectory() throws -> URL {
    let temporaryPath = FileManager.default.temporaryDirectory.path
    var resolvedPath = [CChar](repeating: 0, count: Int(PATH_MAX))
    let didResolve = resolvedPath.withUnsafeMutableBufferPointer { buffer in
      temporaryPath.withCString { source in
        Darwin.realpath(source, buffer.baseAddress) != nil
      }
    }
    guard didResolve else {
      throw TestError.couldNotResolveTemporaryDirectory
    }
    let resolvedPathBytes = resolvedPath.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    let directory = URL(
      fileURLWithPath: String(decoding: resolvedPathBytes, as: UTF8.self),
      isDirectory: true
    ).appendingPathComponent(
      "hex-resident-config-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    return directory
  }

  private enum TestError: Error, Sendable {
    case couldNotResolveTemporaryDirectory
  }

  private func makePaths(in root: URL) throws -> HexResidentDataPaths {
    try HexResidentDataPaths(
      settingsURL: root.appendingPathComponent("resident.json", isDirectory: false),
      databaseURL: root.appendingPathComponent("journal.sqlite", isDirectory: false),
      heartbeatStoreURL: root.appendingPathComponent("heartbeats.json", isDirectory: false)
    )
  }

  private actor SettingsStore: HexResidentRuntimeSettingsStore {
    let value: HexResidentRuntimeSettings

    init(value: HexResidentRuntimeSettings) {
      self.value = value
    }

    func load() async throws -> HexResidentRuntimeSettings? {
      value
    }

    func save(_ settings: HexResidentRuntimeSettings) async throws {
      _ = settings
    }
  }

  private actor SecretStore: HexSecretStore {
    private var value: String?
    private var didRead = false
    private var didCheck = false

    init(value: String?) {
      self.value = value
    }

    func secret(for key: HexSecretKey) async throws -> String {
      guard key == .openAIAPIKey, let value else {
        throw SecretStoreError.missing
      }
      didRead = true
      return value
    }

    func exists(_ key: HexSecretKey) async throws -> Bool {
      didCheck = true
      return key == .openAIAPIKey && value != nil
    }

    func save(_ secret: String, for key: HexSecretKey) async throws {
      guard key == .openAIAPIKey else {
        throw SecretStoreError.missing
      }
      value = secret
    }

    func delete(_ key: HexSecretKey) async throws {
      guard key == .openAIAPIKey else {
        throw SecretStoreError.missing
      }
      value = nil
    }

    func didReadValue() -> Bool {
      didRead
    }

    func didCheckExistence() -> Bool {
      didCheck
    }
  }

  private actor BackendSettingsStore: HexInferenceBackendSettingsStore {
    let value: HexInferenceBackendSettings

    init(value: HexInferenceBackendSettings) {
      self.value = value
    }

    func load() async throws -> HexInferenceBackendSettings? {
      value
    }

    func save(_ settings: HexInferenceBackendSettings) async throws {
      _ = settings
    }
  }

  private enum SecretStoreError: Error, Sendable {
    case missing
  }
}
