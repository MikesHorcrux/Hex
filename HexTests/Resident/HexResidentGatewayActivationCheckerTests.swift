import Foundation
import HexCore
import HexGatewayKit
import HexMCP
import Testing

@testable import Hex

@Suite("Resident activation readiness")
struct HexResidentGatewayActivationCheckerTests {
  @Test
  func missingCredentialBlocksAnOtherwiseValidBundle() async throws {
    let workspace = try makeWorkspace()
    let bundle = try makeBundle()
    defer {
      try? FileManager.default.removeItem(at: workspace)
      try? FileManager.default.removeItem(at: bundle)
    }
    let settings = try HexResidentRuntimeSettings(
      modelID: "gpt-5",
      workspaceRoot: workspace
    )
    let checker = HexResidentGatewayActivationChecker(
      settingsStore: FakeSettingsStore(settings: settings),
      secretStore: FakeSecretStore(),
      appBundleURL: bundle
    )

    let readiness = await checker.check()

    #expect(!readiness.isReady)
    #expect(readiness.message.contains("missing an OpenAI API key"))
  }

  @Test
  func validSettingsCredentialAndBundleAreReady() async throws {
    let workspace = try makeWorkspace()
    let bundle = try makeBundle()
    defer {
      try? FileManager.default.removeItem(at: workspace)
      try? FileManager.default.removeItem(at: bundle)
    }
    let settings = try HexResidentRuntimeSettings(
      modelID: "gpt-5-codex",
      workspaceRoot: workspace
    )
    let checker = HexResidentGatewayActivationChecker(
      settingsStore: FakeSettingsStore(settings: settings),
      secretStore: FakeSecretStore(value: "stored-secret"),
      appBundleURL: bundle
    )

    let readiness = await checker.check()

    #expect(readiness == .ready)
  }

  @Test
  func chatGPTSelectionRequiresOAuthInsteadOfAnAPIKey() async throws {
    let workspace = try makeWorkspace()
    let bundle = try makeBundle()
    defer {
      try? FileManager.default.removeItem(at: workspace)
      try? FileManager.default.removeItem(at: bundle)
    }
    let settings = try HexResidentRuntimeSettings(
      modelID: "subscription-model",
      workspaceRoot: workspace
    )
    let inferenceSettings = try HexInferenceBackendSettings(
      openAIModelID: "subscription-model",
      openAIAuthenticationMethod: .chatGPT
    )
    let checker = HexResidentGatewayActivationChecker(
      settingsStore: FakeSettingsStore(settings: settings),
      secretStore: FakeSecretStore(value: "stored-api-key"),
      appBundleURL: bundle,
      inferenceSettingsStore: FakeInferenceSettingsStore(settings: inferenceSettings)
    )

    let readiness = await checker.check()

    #expect(!readiness.isReady)
    #expect(readiness.message.contains("needs ChatGPT sign-in"))
  }

  @Test
  func absentInferenceDocumentPreservesLegacyAPIKeyRequirement() async throws {
    let workspace = try makeWorkspace()
    let bundle = try makeBundle()
    defer {
      try? FileManager.default.removeItem(at: workspace)
      try? FileManager.default.removeItem(at: bundle)
    }
    let settings = try HexResidentRuntimeSettings(
      modelID: "legacy-model",
      workspaceRoot: workspace
    )
    let checker = HexResidentGatewayActivationChecker(
      settingsStore: FakeSettingsStore(settings: settings),
      secretStore: FakeSecretStore(),
      appBundleURL: bundle,
      inferenceSettingsStore: FakeInferenceSettingsStore(settings: nil)
    )

    let readiness = await checker.check()

    #expect(!readiness.isReady)
    #expect(readiness.message.contains("missing an OpenAI API key"))
  }

  @Test
  func localMLXDoesNotRequireAnOpenAICredential() async throws {
    let workspace = try makeWorkspace()
    let bundle = try makeBundle()
    defer {
      try? FileManager.default.removeItem(at: workspace)
      try? FileManager.default.removeItem(at: bundle)
    }
    let settings = try HexResidentRuntimeSettings(
      modelID: "local-model",
      workspaceRoot: workspace
    )
    let inferenceSettings = try HexInferenceBackendSettings(
      selectedBackend: .mlxLocal,
      mlx: HexMLXBackendSettings(
        modelID: "local-model",
        displayName: "Local model",
        directory: workspace
      )
    )
    let checker = HexResidentGatewayActivationChecker(
      settingsStore: FakeSettingsStore(settings: settings),
      secretStore: FakeSecretStore(),
      appBundleURL: bundle,
      inferenceSettingsStore: FakeInferenceSettingsStore(settings: inferenceSettings)
    )

    let readiness = await checker.check()

    #expect(readiness == .ready)
  }

  @Test
  func enabledManagedToolMustHaveAValidatedInstallation() async throws {
    let workspace = try makeWorkspace()
    let bundle = try makeBundle()
    let toolsRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      "HexActivationTools-\(UUID().uuidString)",
      isDirectory: true
    )
    defer {
      try? FileManager.default.removeItem(at: workspace)
      try? FileManager.default.removeItem(at: bundle)
    }
    let settings = try HexResidentRuntimeSettings(
      modelID: "gpt-5-codex",
      workspaceRoot: workspace,
      mcpServers: [try .playwright()]
    )
    let checker = HexResidentGatewayActivationChecker(
      settingsStore: FakeSettingsStore(settings: settings),
      secretStore: FakeSecretStore(value: "stored-secret"),
      appBundleURL: bundle,
      managedToolLayout: try MCPManagedToolLayout(rootURL: toolsRoot)
    )

    let readiness = await checker.check()

    #expect(!readiness.isReady)
    #expect(readiness.message.contains("managed MCP tool is missing or incomplete"))
  }

  @Test
  func incorrectBundleProgramRemainsBlocked() async throws {
    let workspace = try makeWorkspace()
    let bundle = try makeBundle(bundleProgram: "Contents/Resources/OtherHelper")
    defer {
      try? FileManager.default.removeItem(at: workspace)
      try? FileManager.default.removeItem(at: bundle)
    }
    let settings = try HexResidentRuntimeSettings(
      modelID: "gpt-5",
      workspaceRoot: workspace
    )
    let checker = HexResidentGatewayActivationChecker(
      settingsStore: FakeSettingsStore(settings: settings),
      secretStore: FakeSecretStore(value: "stored-secret"),
      appBundleURL: bundle
    )

    let readiness = await checker.check()

    #expect(!readiness.isReady)
    #expect(readiness.message.contains("wrong helper path"))
  }

  private static func makeWorkspace() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "HexActivationWorkspace-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: false
    )
    return url
  }

  private static func makeBundle(
    bundleProgram: String = HexGatewayServiceIdentity.bundledExecutablePath
  )
    throws -> URL
  {
    let bundle = FileManager.default.temporaryDirectory.appendingPathComponent(
      "HexActivationBundle-\(UUID().uuidString).app",
      isDirectory: true
    )
    let helperURL = bundle.appendingPathComponent("Contents/Resources/HexGateway")
    let plistURL = bundle.appendingPathComponent(
      "Contents/Library/LaunchAgents/com.lunarmothstudios.hex.gateway.plist"
    )
    try FileManager.default.createDirectory(
      at: helperURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: plistURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    guard FileManager.default.createFile(atPath: helperURL.path, contents: Data([0x23])) else {
      throw FixtureError.couldNotCreateHelper
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o755)],
      ofItemAtPath: helperURL.path
    )
    let plistData = try PropertyListSerialization.data(
      fromPropertyList: [
        "Label": HexGatewayServiceIdentity.launchAgentLabel,
        "BundleProgram": bundleProgram,
        "MachServices": [HexGatewayServiceIdentity.machServiceName: true],
        "RunAtLoad": true,
        "KeepAlive": ["SuccessfulExit": false],
        "ThrottleInterval": 10,
      ],
      format: .xml,
      options: 0
    )
    try plistData.write(to: plistURL, options: .atomic)
    return bundle
  }

  private func makeWorkspace() throws -> URL {
    try Self.makeWorkspace()
  }

  private func makeBundle(bundleProgram: String = HexGatewayServiceIdentity.bundledExecutablePath)
    throws -> URL
  {
    try Self.makeBundle(bundleProgram: bundleProgram)
  }

  private enum FixtureError: Error, Sendable {
    case couldNotCreateHelper
    case missingSecret
  }

  private actor FakeSettingsStore: HexResidentRuntimeSettingsStore {
    let settings: HexResidentRuntimeSettings?

    init(settings: HexResidentRuntimeSettings?) {
      self.settings = settings
    }

    func load() async throws -> HexResidentRuntimeSettings? {
      settings
    }

    func save(_ settings: HexResidentRuntimeSettings) async throws {}
  }

  private actor FakeSecretStore: HexSecretStore {
    let value: String?
    let availableKey: HexSecretKey

    init(value: String? = nil, availableKey: HexSecretKey = .openAIAPIKey) {
      self.value = value
      self.availableKey = availableKey
    }

    func secret(for key: HexSecretKey) async throws -> String {
      guard key == availableKey, let value else { throw FixtureError.missingSecret }
      return value
    }

    func exists(_ key: HexSecretKey) async throws -> Bool {
      key == availableKey && value != nil
    }

    func save(_ secret: String, for key: HexSecretKey) async throws {}

    func delete(_ key: HexSecretKey) async throws {}
  }

  private actor FakeInferenceSettingsStore: HexInferenceBackendSettingsStore {
    let settings: HexInferenceBackendSettings?

    init(settings: HexInferenceBackendSettings?) {
      self.settings = settings
    }

    func load() async throws -> HexInferenceBackendSettings? {
      settings
    }

    func save(_ settings: HexInferenceBackendSettings) async throws {}
  }
}
