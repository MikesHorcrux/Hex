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
      workspaceRoot: URL(fileURLWithPath: "/tmp/hex-workspace")
    )
    let settingsStore = SettingsStore(value: settings)
    let secretStore = SecretStore(value: "sk-persisted-secret")

    let configuration = try await HexGatewayResidentConfiguration.loadPersisted(
      paths: paths,
      settingsStore: settingsStore,
      secretStore: secretStore
    )

    #expect(configuration.modelID == "gpt-persisted")
    #expect(configuration.workspaceRoot.path == "/tmp/hex-workspace")
    #expect(configuration.databaseURL == paths.databaseURL)
    #expect(configuration.heartbeatStoreURL == paths.heartbeatStoreURL)
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
        heartbeatStoreURL: URL(fileURLWithPath: "/tmp/."),
        apiKey: "sk-test"
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
        heartbeatStoreURL: URL(fileURLWithPath: "/"),
        apiKey: "sk-test"
      )
      Issue.record("Expected a standardized heartbeat directory to be rejected.")
    } catch let error as HexGatewayResidentConfiguration.ConfigurationError {
      #expect(error == .invalidVariable("HEX_HEARTBEAT_STORE_URL"))
    }
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
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
      key == .openAIAPIKey && value != nil
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
  }

  private enum SecretStoreError: Error, Sendable {
    case missing
  }
}
