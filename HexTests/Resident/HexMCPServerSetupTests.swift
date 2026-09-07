import Foundation
import HexCore
import Testing

@testable import Hex

@Suite("MCP server setup keeps credentials separate from saved configuration")
struct HexMCPServerSetupTests {
  @Test @MainActor
  func bearerTokenIsStagedAndLoadedWithoutReadingItsValue() async throws {
    let settings = try settings()
    let store = SettingsStore(settings)
    let secrets = SecretStore()
    let reloader = Reloader()
    let model = HexResidentSetupModel(
      settingsStore: store, secretStore: secrets, configurationReloader: reloader)
    await model.load()
    #expect(
      model.addHTTPMCPServer(serverID: "local", endpoint: endpoint, bearerToken: "fixture-token"))
    #expect(await secrets.saveCount == 0)
    #expect(model.hasPendingBearerTokenChange("local"))

    #expect(await model.saveAndWait())
    let saved = try #require(await store.value)
    #expect(saved.mcpServers.first?.requiresBearerToken == true)
    #expect(
      !String(decoding: try JSONEncoder().encode(saved), as: UTF8.self).contains("fixture-token"))
    let key = try tokenKey()
    #expect(await secrets.value(for: key) == "fixture-token")
    #expect(!model.hasPendingBearerTokenChange("local"))
    #expect(model.httpMCPServers.first?.hasStoredBearerToken == true)
    #expect(reloader.reloadCount == 1)

    let reopened = HexResidentSetupModel(settingsStore: store, secretStore: secrets)
    await reopened.load()
    #expect(reopened.httpMCPServers.first?.hasStoredBearerToken == true)
    #expect(await secrets.secretReadCount == 0)
  }

  @Test @MainActor
  func failedSettingsWriteNeverChangesAnActiveToken() async throws {
    let store = SettingsStore(try settings(server: authenticatedServer()), failures: 1)
    let key = try tokenKey()
    let secrets = SecretStore(values: [key: "old-token"])
    let reloader = Reloader()
    let model = HexResidentSetupModel(
      settingsStore: store, secretStore: secrets, configurationReloader: reloader)
    await model.load()
    #expect(model.stageHTTPMCPBearerToken("local", token: "replacement-token"))
    #expect(!(await model.saveAndWait()))
    #expect(await secrets.value(for: key) == "old-token")
    #expect(await secrets.saveCount == 0)
    #expect(await secrets.deleteCount == 0)
    #expect(model.hasPendingBearerTokenChange("local"))
    #expect(reloader.reloadCount == 0)

    #expect(await model.saveAndWait())
    #expect(await secrets.value(for: key) == "replacement-token")
  }

  @Test @MainActor
  func failedCredentialWritePreservesDraftAndReportsPartialSave() async throws {
    let store = SettingsStore(try settings())
    let secrets = SecretStore(saveFailures: 1)
    let reloader = Reloader()
    let model = HexResidentSetupModel(
      settingsStore: store, secretStore: secrets, configurationReloader: reloader)
    await model.load()
    #expect(
      model.addHTTPMCPServer(serverID: "local", endpoint: endpoint, bearerToken: "fixture-token"))
    #expect(!(await model.saveAndWait()))
    #expect(await store.value?.mcpServers.first?.requiresBearerToken == true)
    #expect(model.errorMessage?.contains("Settings were saved") == true)
    #expect(model.errorMessage?.contains("credential") == true)
    #expect(model.hasPendingBearerTokenChange("local"))
    #expect(model.saveGeneration == 0)
    #expect(reloader.reloadCount == 0)
    #expect(await model.saveAndWait())
    #expect(reloader.reloadCount == 1)
  }

  @Test @MainActor
  func failedApplyDistinguishesStoredTokenFromAnUnstoredDraft() async throws {
    let store = SettingsStore(try settings())
    let secrets = SecretStore()
    let reloader = Reloader(failures: 1)
    let model = HexResidentSetupModel(
      settingsStore: store, secretStore: secrets, configurationReloader: reloader)
    await model.load()
    #expect(
      model.addHTTPMCPServer(serverID: "local", endpoint: endpoint, bearerToken: "saved-token"))
    #expect(!(await model.saveAndWait()))
    #expect(model.hasPendingBearerTokenChange("local"))
    #expect(model.isBearerTokenChangeStored("local"))
    #expect(model.httpMCPServers.first?.hasStoredBearerToken == true)
    #expect(model.errorMessage?.contains("could not apply") == true)
    #expect(model.saveGeneration == 0)
    #expect(await model.saveAndWait())
    #expect(!model.hasPendingBearerTokenChange("local"))
    #expect(!model.isBearerTokenChangeStored("local"))
    #expect(model.saveGeneration == 1)
  }

  @Test(arguments: [true, false]) @MainActor
  func unavailableOptionalTokenStatusAllowsSettingsRepair(isEnabled: Bool) async throws {
    let store = SettingsStore(try settings(server: authenticatedServer()))
    let key = try tokenKey()
    let secrets = SecretStore(unavailableExistenceKeys: [key])
    let model = HexResidentSetupModel(settingsStore: store, secretStore: secrets)
    await model.load()

    #expect(model.canEditMCPServers)
    #expect(model.canSave)
    #expect(model.httpMCPServers.first?.hasStoredBearerToken == nil)
    #expect(model.errorMessage == nil)
    model.setHTTPMCPServerEnabled("local", isEnabled: isEnabled)
    #expect(await model.saveAndWait())
    #expect(await store.value?.mcpServers.first?.isEnabled == isEnabled)
    #expect(model.httpMCPServers.first?.hasStoredBearerToken == nil)
    #expect(await secrets.secretReadCount == 0)
  }

  @Test @MainActor
  func removingTokenWaitsForSettingsWriteAndNeverFallsBackToStoredAuthorization() async throws {
    let store = SettingsStore(try settings(server: authenticatedServer()), failures: 1)
    let key = try tokenKey()
    let secrets = SecretStore(values: [key: "old-token"])
    let model = HexResidentSetupModel(settingsStore: store, secretStore: secrets)
    await model.load()
    model.removeHTTPMCPBearerToken("local")
    #expect(!(await model.saveAndWait()))
    #expect(await secrets.value(for: key) == "old-token")
    #expect(await secrets.deleteCount == 0)
    #expect(await model.saveAndWait())
    #expect(await store.value?.mcpServers.first?.requiresBearerToken == false)
    #expect(await secrets.value(for: key) == nil)
  }

  @Test @MainActor
  func replacingEndpointDoesNotReusePreviousToken() async throws {
    let store = SettingsStore(try settings(server: authenticatedServer()))
    let key = try tokenKey()
    let secrets = SecretStore(values: [key: "old-token"])
    let model = HexResidentSetupModel(settingsStore: store, secretStore: secrets)
    await model.load()
    model.removeHTTPMCPServer("local")
    #expect(model.addHTTPMCPServer(serverID: "local", endpoint: "http://localhost:9877/mcp"))
    #expect(model.httpMCPServers.first?.requiresBearerToken == false)
    #expect(model.httpMCPServers.first?.hasStoredBearerToken == false)
    #expect(await model.saveAndWait())
    #expect(await secrets.value(for: key) == nil)
    #expect(await secrets.saveCount == 0)
  }

  @Test @MainActor
  func removingAnUnauthenticatedServerDoesNotTouchKeychain() async throws {
    let server = try HexResidentMCPServerSettings(
      serverID: "local", transport: .streamableHTTP, endpointURL: #require(URL(string: endpoint)))
    let store = SettingsStore(try settings(server: server))
    let secrets = SecretStore()
    let model = HexResidentSetupModel(settingsStore: store, secretStore: secrets)
    await model.load()
    model.removeHTTPMCPServer("local")
    #expect(await model.saveAndWait())
    #expect(await store.value?.mcpServers.isEmpty == true)
    #expect(await secrets.deleteCount == 0)
  }

  @Test @MainActor
  func tokensRejectHeaderInjectionBeforePersistence() async throws {
    let store = SettingsStore(try settings())
    let secrets = SecretStore()
    let model = HexResidentSetupModel(settingsStore: store, secretStore: secrets)
    await model.load()
    #expect(
      !model.addHTTPMCPServer(
        serverID: "local", endpoint: endpoint, bearerToken: "token\r\nInjected: value"))
    #expect(model.httpMCPServers.isEmpty)
    #expect(model.addHTTPMCPServer(serverID: "local", endpoint: endpoint))
    #expect(!model.stageHTTPMCPBearerToken("local", token: "contains space"))
    #expect(
      !model.stageHTTPMCPBearerToken("local", token: String(repeating: "a", count: 16 * 1_024)))
    #expect(await secrets.saveCount == 0)
    #expect(await secrets.deleteCount == 0)
  }

  @Test @MainActor
  func connectionEditsCannotRaceAnApplyingSave() async throws {
    let store = SettingsStore(try settings())
    let secrets = SecretStore()
    let reloader = SuspendedReloader()
    defer { reloader.finish() }
    let model = HexResidentSetupModel(
      settingsStore: store, secretStore: secrets, configurationReloader: reloader)
    await model.load()
    #expect(
      model.addHTTPMCPServer(serverID: "local", endpoint: endpoint, bearerToken: "saved-token"))
    let save = Task { await model.saveAndWait() }
    try await reloader.waitUntilSuspended()

    #expect(!model.canEditMCPServers)
    #expect(!model.stageHTTPMCPBearerToken("local", token: "late-token"))
    #expect(!model.addHTTPMCPServer(serverID: "late", endpoint: endpoint))
    #expect(
      !model.addStdioMCPServer(
        serverID: "late", executablePath: "/usr/bin/fixture", argumentsText: "",
        workingDirectoryPath: "/tmp"))
    model.removeHTTPMCPBearerToken("local")
    model.setHTTPMCPServerEnabled("local", isEnabled: false)
    model.removeHTTPMCPServer("local")
    #expect(model.httpMCPServers.first?.requiresBearerToken == true)
    #expect(model.httpMCPServers.first?.isEnabled == true)
    reloader.finish()
    #expect(await save.value)
    let key = try tokenKey()
    #expect(await secrets.value(for: key) == "saved-token")
    #expect(model.canEditMCPServers)
  }

  @Test @MainActor
  func stdioSettingsPreserveLiteralArgumentsAndRejectDuplicateOrRelativePaths() async throws {
    let store = SettingsStore(try settings())
    let model = HexResidentSetupModel(settingsStore: store, secretStore: SecretStore())
    await model.load()
    #expect(
      !model.addStdioMCPServer(
        serverID: "custom", executablePath: "relative/tool", argumentsText: "",
        workingDirectoryPath: "/tmp"))
    #expect(
      model.addStdioMCPServer(
        serverID: "custom", executablePath: "/usr/bin/fixture",
        argumentsText: "--label\na b\n$(touch nope)",
        workingDirectoryPath: "/tmp"))
    #expect(!model.addHTTPMCPServer(serverID: "custom", endpoint: endpoint))
    #expect(
      !model.addStdioMCPServer(
        serverID: "xcode", executablePath: "/usr/bin/fixture", argumentsText: "",
        workingDirectoryPath: "/tmp"))
    model.setStdioMCPServerEnabled("custom", isEnabled: false)
    #expect(await model.saveAndWait())
    let server = try #require(await store.value?.mcpServers.first)
    #expect(server.transport == .stdio)
    #expect(server.arguments == ["--label", "a b", "$(touch nope)"])
    #expect(!server.isEnabled)
    let reopened = HexResidentSetupModel(settingsStore: store, secretStore: SecretStore())
    await reopened.load()
    #expect(reopened.stdioMCPServers.first?.arguments == server.arguments)
    reopened.removeStdioMCPServer("custom")
    #expect(await reopened.saveAndWait())
    #expect(await store.value?.mcpServers.isEmpty == true)
  }

  private var endpoint: String { "http://localhost:9876/mcp" }

  private func tokenKey() throws -> HexSecretKey {
    try .mcpBearerToken(serverID: "local", endpointURL: #require(URL(string: endpoint)))
  }

  private func authenticatedServer() throws -> HexResidentMCPServerSettings {
    try .init(
      serverID: "local", transport: .streamableHTTP,
      endpointURL: #require(URL(string: endpoint)), requiresBearerToken: true)
  }

  private func settings(server: HexResidentMCPServerSettings? = nil) throws
    -> HexResidentRuntimeSettings
  {
    try .init(
      modelID: "fixture", workspaceRoot: FileManager.default.temporaryDirectory,
      mcpServers: server.map { [$0] } ?? [])
  }

  private enum Failure: Error { case unavailable }

  private actor SettingsStore: HexResidentRuntimeSettingsStore {
    private(set) var value: HexResidentRuntimeSettings?
    private var failures: Int

    init(_ value: HexResidentRuntimeSettings, failures: Int = 0) {
      self.value = value
      self.failures = failures
    }

    func load() -> HexResidentRuntimeSettings? { value }
    func save(_ settings: HexResidentRuntimeSettings) throws {
      if failures > 0 {
        failures -= 1
        throw Failure.unavailable
      }
      value = settings
    }
  }

  private actor SecretStore: HexSecretStore {
    private var values: [HexSecretKey: String]
    private var saveFailures: Int
    private let unavailableExistenceKeys: Set<HexSecretKey>
    private(set) var saveCount = 0
    private(set) var deleteCount = 0
    private(set) var secretReadCount = 0

    init(
      values: [HexSecretKey: String] = [:], saveFailures: Int = 0,
      unavailableExistenceKeys: Set<HexSecretKey> = []
    ) {
      self.values = values
      self.saveFailures = saveFailures
      self.unavailableExistenceKeys = unavailableExistenceKeys
    }

    func value(for key: HexSecretKey) -> String? { values[key] }
    func exists(_ key: HexSecretKey) throws -> Bool {
      if unavailableExistenceKeys.contains(key) { throw Failure.unavailable }
      return values[key] != nil
    }
    func secret(for key: HexSecretKey) throws -> String {
      secretReadCount += 1
      return try #require(values[key])
    }
    func save(_ secret: String, for key: HexSecretKey) throws {
      if saveFailures > 0 {
        saveFailures -= 1
        throw Failure.unavailable
      }
      values[key] = secret
      saveCount += 1
    }
    func delete(_ key: HexSecretKey) {
      values[key] = nil
      deleteCount += 1
    }
  }

  @MainActor
  private final class Reloader: HexResidentConfigurationReloading {
    private(set) var reloadCount = 0
    private var failures: Int

    init(failures: Int = 0) { self.failures = failures }

    func reloadAfterConfigurationChange() throws {
      reloadCount += 1
      if failures > 0 {
        failures -= 1
        throw Failure.unavailable
      }
    }
  }

  @MainActor
  private final class SuspendedReloader: HexResidentConfigurationReloading {
    private var continuation: CheckedContinuation<Void, Never>?

    func reloadAfterConfigurationChange() async {
      await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilSuspended() async throws {
      for _ in 0..<100 {
        if continuation != nil { return }
        try await Task.sleep(for: .milliseconds(10))
      }
      throw Failure.unavailable
    }

    func finish() {
      continuation?.resume()
      continuation = nil
    }
  }
}
