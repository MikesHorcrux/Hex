import Foundation
import HexCore
import HexMCP
import Testing

@testable import Hex

@Suite("Resident setup")
struct HexResidentSetupModelTests {
  @Test @MainActor
  func firstSaveRequiresACredential() async throws {
    let settingsStore = FakeSettingsStore()
    let secretStore = FakeSecretStore()
    let model = HexResidentSetupModel(
      settingsStore: settingsStore,
      secretStore: secretStore
    )
    await model.load()

    let workspace = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace) }
    model.modelID = "gpt-5"
    model.chooseWorkspace(workspace)
    model.save()

    #expect(model.errorMessage == "Enter an OpenAI API key before saving for the first time.")
    #expect(!model.isSaving)
    #expect(await settingsStore.savedSettings == nil)
    #expect(await secretStore.saveCount == 0)
  }

  @Test @MainActor
  func blankCredentialPreservesExistingKey() async throws {
    let workspace = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let settings = try HexResidentRuntimeSettings(
      modelID: "existing-model",
      workspaceRoot: workspace
    )
    let settingsStore = FakeSettingsStore(settings: settings)
    let secretStore = FakeSecretStore(value: "existing-secret")
    let model = HexResidentSetupModel(
      settingsStore: settingsStore,
      secretStore: secretStore
    )
    await model.load()

    model.modelID = "updated-model"
    model.save()
    try await waitForSave(model)

    #expect(await secretStore.saveCount == 0)
    #expect(await secretStore.value == "existing-secret")
    #expect(await settingsStore.savedSettings?.modelID == "updated-model")
    #expect(model.apiKey.isEmpty)
    #expect(model.errorMessage == nil)
  }

  @Test @MainActor
  func savePersistsSettingsAndCredentialWithoutEchoingSecret() async throws {
    let settingsStore = FakeSettingsStore()
    let secretStore = FakeSecretStore()
    let model = HexResidentSetupModel(
      settingsStore: settingsStore,
      secretStore: secretStore
    )
    await model.load()

    let workspace = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace) }
    model.modelID = "gpt-5-codex"
    model.apiKey = "sk-test-value"
    model.xcodeMCPEnabled = true
    model.chooseWorkspace(workspace)
    model.save()
    try await waitForSave(model)

    #expect(await settingsStore.savedSettings?.modelID == "gpt-5-codex")
    #expect(await settingsStore.savedSettings?.workspaceRoot == workspace.standardizedFileURL)
    #expect(await settingsStore.savedSettings?.mcpServers == [try .xcode()])
    #expect(await secretStore.value == "sk-test-value")
    #expect(model.apiKey.isEmpty)
    #expect(model.hasStoredAPIKey)
    #expect(model.statusMessage == "Resident settings saved.")
    #expect(model.errorMessage == nil)
  }

  @Test @MainActor
  func savePersistsInstalledBrowserAndMacIntegrations() async throws {
    let installation = try makeManagedToolInstallation()
    defer { try? FileManager.default.removeItem(at: installation.rootURL) }
    let settingsStore = FakeSettingsStore()
    let secretStore = FakeSecretStore()
    let model = HexResidentSetupModel(
      settingsStore: settingsStore,
      secretStore: secretStore,
      managedToolLayout: installation.layout
    )
    await model.load()

    let workspace = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace) }
    model.modelID = "gpt-5-codex"
    model.apiKey = "sk-test-value"
    model.peekabooMCPEnabled = true
    model.playwrightMCPEnabled = true
    model.xcodeMCPEnabled = true
    model.chooseWorkspace(workspace)
    model.save()
    try await waitForSave(model)

    #expect(model.peekabooAvailability == .ready)
    #expect(model.playwrightAvailability == .ready)
    #expect(
      await settingsStore.savedSettings?.mcpServers
        == [try .peekaboo(), try .playwright(), try .xcode()]
    )
    #expect(model.errorMessage == nil)
  }

  @Test @MainActor
  func loadAndSavePreserveHTTPServersWhileTogglingXcode() async throws {
    let workspace = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let httpServer = try HexResidentMCPServerSettings(
      serverID: "docs",
      transport: .streamableHTTP,
      endpointURL: URL(string: "https://mcp.example.com")
    )
    let settings = try HexResidentRuntimeSettings(
      modelID: "existing-model",
      workspaceRoot: workspace,
      mcpServers: [httpServer, try .xcode()]
    )
    let settingsStore = FakeSettingsStore(settings: settings)
    let secretStore = FakeSecretStore(value: "existing-secret")
    let model = HexResidentSetupModel(
      settingsStore: settingsStore,
      secretStore: secretStore
    )

    await model.load()
    #expect(model.xcodeMCPEnabled)
    model.xcodeMCPEnabled = false
    model.save()
    try await waitForSave(model)

    #expect(await settingsStore.savedSettings?.mcpServers == [httpServer])
  }

  @Test @MainActor
  func managesValidatedHTTPServersWithoutPersistingDrafts() async throws {
    let workspace = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace) }
    let settings = try HexResidentRuntimeSettings(
      modelID: "existing-model",
      workspaceRoot: workspace
    )
    let settingsStore = FakeSettingsStore(settings: settings)
    let secretStore = FakeSecretStore(value: "existing-secret")
    let model = HexResidentSetupModel(
      settingsStore: settingsStore,
      secretStore: secretStore
    )
    await model.load()

    #expect(
      model.addHTTPMCPServer(
        serverID: "local_docs",
        endpoint: "http://localhost:8765/mcp"
      )
    )
    #expect(
      !model.addHTTPMCPServer(
        serverID: "playwright",
        endpoint: "http://localhost:9999/mcp"
      )
    )
    model.setHTTPMCPServerEnabled("local_docs", isEnabled: false)
    model.save()
    try await waitForSave(model)

    let savedServer = try #require(await settingsStore.savedSettings?.mcpServers.first)
    #expect(savedServer.serverID == "local_docs")
    #expect(savedServer.endpointURL?.absoluteString == "http://localhost:8765/mcp")
    #expect(!savedServer.isEnabled)

    model.removeHTTPMCPServer("local_docs")
    model.save()
    try await waitForSave(model)
    #expect(await settingsStore.savedSettings?.mcpServers.isEmpty == true)
  }

  @Test @MainActor
  func invalidWorkspaceDoesNotStartAPersistenceTask() async {
    let settingsStore = FakeSettingsStore()
    let secretStore = FakeSecretStore()
    let model = HexResidentSetupModel(
      settingsStore: settingsStore,
      secretStore: secretStore
    )
    await model.load()

    model.modelID = "gpt-5"
    model.apiKey = "sk-test-value"
    model.save()

    #expect(model.errorMessage == "Choose an existing local workspace folder before saving.")
    #expect(!model.isSaving)
    #expect(await settingsStore.saveCount == 0)
    #expect(await secretStore.saveCount == 0)
  }

  private static func makeWorkspace() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "HexResidentSetup-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: false
    )
    return url
  }

  private func makeWorkspace() throws -> URL {
    try Self.makeWorkspace()
  }

  private func makeManagedToolInstallation() throws -> (
    rootURL: URL,
    layout: MCPManagedToolLayout
  ) {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "HexManagedTools-\(UUID().uuidString)",
      isDirectory: true
    )
    let layout = try MCPManagedToolLayout(rootURL: rootURL)
    try writeFixture("node", to: layout.nodeExecutableURL, executable: true)
    try writeFixture("node-script", to: layout.playwrightServerScriptURL)
    let manifest = try JSONSerialization.data(
      withJSONObject: [
        "name": "@playwright/mcp",
        "version": MCPManagedToolLayout.playwrightVersion,
        "license": "Apache-2.0",
      ],
      options: [.sortedKeys]
    )
    try writeFixture(manifest, to: layout.playwrightPackageManifestURL)
    try writeFixture("browser", to: layout.playwrightBrowserExecutableURL, executable: true)
    try writeFixture("peekaboo", to: layout.peekabooExecutableURL, executable: true)
    try writeFixture(
      MCPManagedToolLayout.peekabooVersion,
      to: layout.peekabooVersionFileURL
    )
    return (rootURL, layout)
  }

  private func writeFixture(
    _ value: String,
    to url: URL,
    executable: Bool = false
  ) throws {
    try writeFixture(Data(value.utf8), to: url, executable: executable)
  }

  private func writeFixture(
    _ data: Data,
    to url: URL,
    executable: Bool = false
  ) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: url, options: .atomic)
    if executable {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: url.path
      )
    }
  }

  @MainActor
  private func waitForSave(_ model: HexResidentSetupModel) async throws {
    for _ in 0..<100 {
      if !model.isSaving {
        return
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    Issue.record("Resident setup save did not finish within the test budget.")
  }

  private enum FakeStoreError: Error, Sendable {
    case missingSettings
    case missingSecret
  }

  private actor FakeSettingsStore: HexResidentRuntimeSettingsStore {
    private var settings: HexResidentRuntimeSettings?
    private(set) var savedSettings: HexResidentRuntimeSettings?
    private(set) var saveCount = 0

    init(settings: HexResidentRuntimeSettings? = nil) {
      self.settings = settings
    }

    func load() async throws -> HexResidentRuntimeSettings? {
      settings
    }

    func save(_ settings: HexResidentRuntimeSettings) async throws {
      self.settings = settings
      savedSettings = settings
      saveCount += 1
    }
  }

  private actor FakeSecretStore: HexSecretStore {
    private(set) var value: String?
    private(set) var saveCount = 0

    init(value: String? = nil) {
      self.value = value
    }

    func secret(for key: HexSecretKey) async throws -> String {
      guard let value else { throw FakeStoreError.missingSecret }
      return value
    }

    func exists(_ key: HexSecretKey) async throws -> Bool {
      value != nil
    }

    func save(_ secret: String, for key: HexSecretKey) async throws {
      value = secret
      saveCount += 1
    }

    func delete(_ key: HexSecretKey) async throws {
      value = nil
    }
  }
}
