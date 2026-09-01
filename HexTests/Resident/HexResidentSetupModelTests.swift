import Foundation
import HexCore
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
    model.chooseWorkspace(workspace)
    model.save()
    try await waitForSave(model)

    #expect(await settingsStore.savedSettings?.modelID == "gpt-5-codex")
    #expect(await settingsStore.savedSettings?.workspaceRoot == workspace.standardizedFileURL)
    #expect(await secretStore.value == "sk-test-value")
    #expect(model.apiKey.isEmpty)
    #expect(model.hasStoredAPIKey)
    #expect(model.statusMessage == "Resident settings saved.")
    #expect(model.errorMessage == nil)
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
