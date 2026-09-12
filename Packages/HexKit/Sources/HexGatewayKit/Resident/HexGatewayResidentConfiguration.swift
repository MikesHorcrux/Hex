import Foundation
import HexCore
import HexIPC
import HexMCP
import HexPersistence
import HexPersonality
import HexProviders

/// Resident gateway composition settings. Credentials are injected as a provider and are never
/// part of this value's persisted, Codable, or diagnostic surface. The `SMAppService` launch path
/// loads non-secret settings from Application Support and credentials from the shared data-protection
/// Keychain; this type deliberately does not place secrets in a launch-agent plist.
public struct HexGatewayResidentConfiguration: Sendable {
  private static let apiKeyVariable = "HEX_OPENAI_API_KEY"
  private static let modelVariable = "HEX_OPENAI_MODEL"
  private static let workspaceVariable = "HEX_WORKSPACE_ROOT"
  private static let serviceVariable = "HEX_GATEWAY_MACH_SERVICE"
  private static let databaseVariable = "HEX_GATEWAY_DATABASE_URL"
  private static let heartbeatStoreVariable = "HEX_HEARTBEAT_STORE_URL"
  private static let heartbeatDatabaseVariable = "HEX_HEARTBEAT_DATABASE_URL"
  private static let xcodeMCPVariable = "HEX_XCODE_MCP_ENABLED"
  private static let personalityScopeVariable = "HEX_PERSONALITY_SCOPE"

  public let machServiceName: String
  public let modelID: String
  public let workspaceRoot: URL
  public let databaseURL: URL
  public let heartbeatStoreURL: URL
  /// The original URL remains the legacy import source; this is the resident's active database.
  public var heartbeatDatabaseURL: URL { heartbeatStoreURL.appendingPathExtension("sqlite") }
  public let personalityProfileURL: URL
  public let personalMemoryURL: URL
  /// Known file-backed stores only; environment overrides and opaque injected stores leave nil.
  public let settingsFileURL: URL?
  public let inferenceSettingsFileURL: URL?
  public let personalMemoryScope: PersonalMemoryScope
  public let connectionAdmissionPolicy: HexGatewayConnectionAdmissionPolicy
  public let authorizationMode: HexAuthorizationMode
  public let openAIAuthorizationProvider: any OpenAIResponsesAuthorizationProvider
  public let inferenceBackendSettings: HexInferenceBackendSettings
  public let inferenceProviderFactory: HexGatewayInferenceProviderFactory
  public let mcpClientSessions: [any MCPClientSession]
  public let mcpServerSettings: [HexResidentMCPServerSettings]
  public let managedToolLayout: MCPManagedToolLayout?

  /// Parses the complete, explicit developer environment override. The API key remains in the
  /// resulting process-only memory provider and is never copied to a persisted settings file.
  public init(environment: [String: String]) throws {
    var missing: [String] = []
    let apiKey = Self.value(named: Self.apiKeyVariable, in: environment)
    let modelID = Self.value(named: Self.modelVariable, in: environment)
    let workspace = Self.value(named: Self.workspaceVariable, in: environment)
    if apiKey == nil {
      missing.append(Self.apiKeyVariable)
    }
    if modelID == nil {
      missing.append(Self.modelVariable)
    }
    if workspace == nil {
      missing.append(Self.workspaceVariable)
    }
    guard missing.isEmpty else {
      throw HexGatewayResidentConfigurationError.missingVariables(missing)
    }
    guard let apiKey, let modelID, let workspace else {
      throw HexGatewayResidentConfigurationError.missingVariables(missing)
    }

    let machServiceName =
      Self.value(named: Self.serviceVariable, in: environment)
      ?? HexGatewayServiceIdentity.machServiceName
    let databaseURL: URL
    if let rawDatabaseURL = Self.value(named: Self.databaseVariable, in: environment) {
      databaseURL = URL(fileURLWithPath: rawDatabaseURL, isDirectory: false)
    } else {
      guard
        let applicationSupport = FileManager.default.urls(
          for: .applicationSupportDirectory,
          in: .userDomainMask
        ).first
      else {
        throw HexGatewayResidentConfigurationError.applicationSupportUnavailable
      }
      databaseURL =
        applicationSupport
        .appendingPathComponent("Hex", isDirectory: true)
        .appendingPathComponent("agent-events.sqlite", isDirectory: false)
    }
    let heartbeatStoreURL: URL
    if let rawHeartbeatStoreURL = Self.value(named: Self.heartbeatStoreVariable, in: environment)
      ?? Self.value(named: Self.heartbeatDatabaseVariable, in: environment)
    {
      heartbeatStoreURL = URL(fileURLWithPath: rawHeartbeatStoreURL, isDirectory: false)
    } else {
      heartbeatStoreURL = databaseURL.deletingLastPathComponent()
        .appendingPathComponent("heartbeats.json", isDirectory: false)
    }
    let personalMemoryScope: PersonalMemoryScope
    if let rawScope = Self.value(named: Self.personalityScopeVariable, in: environment) {
      do {
        personalMemoryScope = try PersonalMemoryScope(rawValue: rawScope)
      } catch {
        throw HexGatewayResidentConfigurationError.invalidVariable(
          Self.personalityScopeVariable)
      }
    } else {
      personalMemoryScope = Self.defaultPersonalityScope()
    }
    let mcpClientSessions: [any MCPClientSession]
    if let rawXcodeMCP = Self.value(named: Self.xcodeMCPVariable, in: environment) {
      switch rawXcodeMCP.lowercased() {
      case "1", "true", "yes":
        do {
          let xcodeEnvironment = try MCPProcessEnvironment.sanitized(from: environment)
          mcpClientSessions = [
            try MCPDeferredClientSession(serverID: "xcode") {
              LocalMCPClientSession(
                configuration: try MCPServerConfiguration.xcode(sourceEnvironment: xcodeEnvironment)
              )
            }
          ]
        } catch {
          throw HexGatewayResidentConfigurationError.mcpConfigurationUnavailable
        }
      case "0", "false", "no":
        mcpClientSessions = []
      default:
        throw HexGatewayResidentConfigurationError.invalidVariable(
          Self.xcodeMCPVariable)
      }
    } else {
      mcpClientSessions = []
    }

    try self.init(
      machServiceName: machServiceName,
      modelID: modelID,
      workspaceRoot: URL(fileURLWithPath: workspace, isDirectory: true),
      databaseURL: databaseURL,
      apiKey: apiKey,
      heartbeatStoreURL: heartbeatStoreURL,
      personalMemoryScope: personalMemoryScope,
      mcpClientSessions: mcpClientSessions,
      connectionAdmissionPolicy: .production()
    )
  }

  /// Creates a configuration around a caller-owned OpenAI authorization provider. The provider is
  /// queried only immediately before a request, so this initializer never receives or encodes a
  /// secret value.
  public init(
    machServiceName: String,
    modelID: String,
    workspaceRoot: URL,
    databaseURL: URL,
    authorizationProvider: any OpenAIResponsesAuthorizationProvider,
    heartbeatStoreURL: URL? = nil,
    personalityProfileURL: URL? = nil,
    personalMemoryURL: URL? = nil,
    settingsFileURL: URL? = nil,
    inferenceSettingsFileURL: URL? = nil,
    personalMemoryScope: PersonalMemoryScope? = nil,
    mcpClientSessions: [any MCPClientSession] = [],
    mcpServerSettings: [HexResidentMCPServerSettings] = [],
    managedToolLayout: MCPManagedToolLayout? = nil,
    authorizationMode: HexAuthorizationMode = .askEveryTime,
    connectionAdmissionPolicy: HexGatewayConnectionAdmissionPolicy = .production(),
    inferenceBackendSettings: HexInferenceBackendSettings? = nil,
    inferenceProviderFactory: HexGatewayInferenceProviderFactory =
      HexGatewayInferenceProviderFactory()
  ) throws {
    guard Self.isPrintableASCII(machServiceName), machServiceName.utf8.count <= 256 else {
      throw HexGatewayResidentConfigurationError.invalidVariable(Self.serviceVariable)
    }
    guard Self.isPrintableASCII(modelID), modelID.utf8.count <= 512 else {
      throw HexGatewayResidentConfigurationError.invalidVariable(Self.modelVariable)
    }
    let resolvedInferenceBackendSettings =
      try inferenceBackendSettings
      ?? HexInferenceBackendSettings(openAIModelID: modelID)
    let resolvedModelID = Self.modelID(
      for: resolvedInferenceBackendSettings,
      fallback: modelID
    )
    guard Self.isPrintableASCII(resolvedModelID), resolvedModelID.utf8.count <= 512 else {
      throw HexGatewayResidentConfigurationError.invalidVariable(Self.modelVariable)
    }
    let standardizedWorkspaceRoot = workspaceRoot.standardizedFileURL
    guard
      Self.isAbsoluteFileURL(workspaceRoot),
      Self.isAbsoluteFileURL(standardizedWorkspaceRoot)
    else {
      throw HexGatewayResidentConfigurationError.invalidVariable(
        Self.workspaceVariable)
    }
    let standardizedDatabaseURL = databaseURL.standardizedFileURL
    guard
      Self.isValidDataFileURL(databaseURL),
      Self.isValidDataFileURL(standardizedDatabaseURL)
    else {
      throw HexGatewayResidentConfigurationError.invalidVariable(Self.databaseVariable)
    }
    let resolvedHeartbeatStoreURL =
      heartbeatStoreURL
      ?? databaseURL.deletingLastPathComponent()
      .appendingPathComponent("heartbeats.json", isDirectory: false)
    let standardizedHeartbeatStoreURL = resolvedHeartbeatStoreURL.standardizedFileURL
    guard
      Self.isValidDataFileURL(resolvedHeartbeatStoreURL),
      Self.isValidDataFileURL(standardizedHeartbeatStoreURL)
    else {
      throw HexGatewayResidentConfigurationError.invalidVariable(
        Self.heartbeatStoreVariable)
    }
    let resolvedPersonalityProfileURL =
      personalityProfileURL
      ?? databaseURL.deletingLastPathComponent()
      .appendingPathComponent("personality-profile.json", isDirectory: false)
    let resolvedPersonalMemoryURL =
      personalMemoryURL
      ?? databaseURL.deletingLastPathComponent()
      .appendingPathComponent("personal-memory.json", isDirectory: false)
    let standardizedPersonalityProfileURL = resolvedPersonalityProfileURL.standardizedFileURL
    let standardizedPersonalMemoryURL = resolvedPersonalMemoryURL.standardizedFileURL
    guard
      Self.isValidDataFileURL(resolvedPersonalityProfileURL),
      Self.isValidDataFileURL(standardizedPersonalityProfileURL)
    else {
      throw HexGatewayResidentConfigurationError.invalidVariable(
        "HEX_PERSONALITY_PROFILE_URL")
    }
    guard
      Self.isValidDataFileURL(resolvedPersonalMemoryURL),
      Self.isValidDataFileURL(standardizedPersonalMemoryURL)
    else {
      throw HexGatewayResidentConfigurationError.invalidVariable(
        "HEX_PERSONAL_MEMORY_URL")
    }
    guard
      mcpClientSessions.count <= 16,
      Set(mcpClientSessions.map(\.serverID)).count == mcpClientSessions.count
    else {
      throw HexGatewayResidentConfigurationError.mcpConfigurationUnavailable
    }

    self.machServiceName = machServiceName
    self.modelID = resolvedModelID
    self.workspaceRoot = standardizedWorkspaceRoot
    self.databaseURL = standardizedDatabaseURL
    self.heartbeatStoreURL = standardizedHeartbeatStoreURL
    self.personalityProfileURL = standardizedPersonalityProfileURL
    self.personalMemoryURL = standardizedPersonalMemoryURL
    self.settingsFileURL = settingsFileURL?.standardizedFileURL
    self.inferenceSettingsFileURL = inferenceSettingsFileURL?.standardizedFileURL
    self.personalMemoryScope = personalMemoryScope ?? Self.defaultPersonalityScope()
    self.connectionAdmissionPolicy = connectionAdmissionPolicy
    self.authorizationMode = authorizationMode
    self.openAIAuthorizationProvider = authorizationProvider
    self.inferenceBackendSettings = resolvedInferenceBackendSettings
    self.inferenceProviderFactory = inferenceProviderFactory
    self.mcpClientSessions = mcpClientSessions.sorted { $0.serverID < $1.serverID }
    self.mcpServerSettings = mcpServerSettings
    self.managedToolLayout = managedToolLayout
  }

  /// Keeps the explicit environment initializer source-compatible for local development and
  /// staging while moving normal resident startup to the injected secret-store path.
  public init(
    machServiceName: String,
    modelID: String,
    workspaceRoot: URL,
    databaseURL: URL,
    apiKey: String,
    heartbeatStoreURL: URL? = nil,
    personalityProfileURL: URL? = nil,
    personalMemoryURL: URL? = nil,
    settingsFileURL: URL? = nil,
    inferenceSettingsFileURL: URL? = nil,
    personalMemoryScope: PersonalMemoryScope? = nil,
    mcpClientSessions: [any MCPClientSession] = [],
    managedToolLayout: MCPManagedToolLayout? = nil,
    authorizationMode: HexAuthorizationMode = .askEveryTime,
    connectionAdmissionPolicy: HexGatewayConnectionAdmissionPolicy = .production(),
    inferenceBackendSettings: HexInferenceBackendSettings? = nil,
    inferenceProviderFactory: HexGatewayInferenceProviderFactory =
      HexGatewayInferenceProviderFactory()
  ) throws {
    guard Self.isPrintableASCII(apiKey) else {
      throw HexGatewayResidentConfigurationError.invalidVariable(Self.apiKeyVariable)
    }
    try self.init(
      machServiceName: machServiceName,
      modelID: modelID,
      workspaceRoot: workspaceRoot,
      databaseURL: databaseURL,
      authorizationProvider: HexGatewayMemoryCredentialProvider(apiKey: apiKey),
      heartbeatStoreURL: heartbeatStoreURL,
      personalityProfileURL: personalityProfileURL,
      personalMemoryURL: personalMemoryURL,
      settingsFileURL: settingsFileURL,
      inferenceSettingsFileURL: inferenceSettingsFileURL,
      personalMemoryScope: personalMemoryScope,
      mcpClientSessions: mcpClientSessions,
      managedToolLayout: managedToolLayout,
      authorizationMode: authorizationMode,
      connectionAdmissionPolicy: connectionAdmissionPolicy,
      inferenceBackendSettings: inferenceBackendSettings,
      inferenceProviderFactory: inferenceProviderFactory
    )
  }

  /// Loads non-secret settings and injects the selected request-time authorization adapter. Secret
  /// values are not read during startup; only Keychain item existence is checked so missing auth
  /// fails before the resident host serves requests.
  public static func loadPersisted(
    paths: HexResidentDataPaths? = nil,
    settingsStore: (any HexResidentRuntimeSettingsStore)? = nil,
    secretStore: (any HexSecretStore)? = nil,
    connectionAdmissionPolicy: HexGatewayConnectionAdmissionPolicy = .production(),
    inferenceBackendSettingsStore: (any HexInferenceBackendSettingsStore)? = nil,
    inferenceProviderFactory: HexGatewayInferenceProviderFactory =
      HexGatewayInferenceProviderFactory()
  ) async throws -> Self {
    let resolvedPaths: HexResidentDataPaths
    do {
      resolvedPaths = try paths ?? HexResidentDataPaths.live()
    } catch {
      throw HexGatewayResidentConfigurationError.applicationSupportUnavailable
    }

    let resolvedSettingsStore: any HexResidentRuntimeSettingsStore
    do {
      if let settingsStore {
        resolvedSettingsStore = settingsStore
      } else {
        resolvedSettingsStore = try JSONHexResidentRuntimeSettingsStore(
          fileURL: resolvedPaths.settingsURL
        )
      }
    } catch {
      throw HexGatewayResidentConfigurationError.settingsUnavailable
    }

    let resolvedInferenceSettingsStore: any HexInferenceBackendSettingsStore
    do {
      if let inferenceBackendSettingsStore {
        resolvedInferenceSettingsStore = inferenceBackendSettingsStore
      } else {
        resolvedInferenceSettingsStore = try JSONHexInferenceBackendSettingsStore(
          fileURL: resolvedPaths.directoryURL.appendingPathComponent(
            "inference-backends.json",
            isDirectory: false
          )
        )
      }
    } catch {
      throw HexGatewayResidentConfigurationError.inferenceSettingsUnavailable
    }

    let settings: HexResidentRuntimeSettings
    do {
      guard let loadedSettings = try await resolvedSettingsStore.load() else {
        throw HexGatewayResidentConfigurationError.settingsUnavailable
      }
      settings = loadedSettings
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw HexGatewayResidentConfigurationError.settingsUnavailable
    }

    let inferenceBackendSettings: HexInferenceBackendSettings
    do {
      if let loadedSettings = try await resolvedInferenceSettingsStore.load() {
        inferenceBackendSettings = loadedSettings
      } else {
        // Migrate the legacy resident model explicitly. The new document defaults to OpenAI so an
        // absent backend file preserves the previously operational resident path.
        inferenceBackendSettings = try HexInferenceBackendSettings.migrationDefault(
          legacyOpenAIModelID: settings.modelID
        )
        try await resolvedInferenceSettingsStore.save(inferenceBackendSettings)
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw HexGatewayResidentConfigurationError.inferenceSettingsUnavailable
    }

    let resolvedSecretStore: any HexSecretStore = secretStore ?? KeychainHexSecretStore()
    if inferenceBackendSettings.selectedBackend == .openAIResponses {
      let requiredSecret: HexSecretKey =
        inferenceBackendSettings.openAI.authenticationMethod == .chatGPT
        ? .openAIChatGPTOAuth
        : .openAIAPIKey
      do {
        guard try await resolvedSecretStore.exists(requiredSecret) else {
          throw HexGatewayResidentConfigurationError.credentialsUnavailable
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as HexGatewayResidentConfigurationError {
        throw error
      } catch {
        throw HexGatewayResidentConfigurationError.credentialsUnavailable
      }
    }

    let managedToolLayout: MCPManagedToolLayout
    let mcpClientSessions: [any MCPClientSession]
    do {
      managedToolLayout = try MCPManagedToolLayout(
        rootURL: resolvedPaths.directoryURL.appendingPathComponent("Tools", isDirectory: true)
      )
      mcpClientSessions = try Self.makeMCPClientSessions(
        from: settings.mcpServers,
        managedToolLayout: managedToolLayout,
        workspaceRoot: settings.workspaceRoot,
        secretStore: resolvedSecretStore
      )
    } catch {
      throw HexGatewayResidentConfigurationError.mcpConfigurationUnavailable
    }

    let authorizationProvider: any OpenAIResponsesAuthorizationProvider =
      inferenceBackendSettings.openAI.authenticationMethod == .chatGPT
      ? ChatGPTCodexOAuthSession(secretStore: resolvedSecretStore)
      : HexSecretStoreOpenAICredentialProvider(store: resolvedSecretStore)

    return try Self(
      machServiceName: HexGatewayServiceIdentity.machServiceName,
      modelID: Self.modelID(for: inferenceBackendSettings, fallback: settings.modelID),
      workspaceRoot: settings.workspaceRoot,
      databaseURL: resolvedPaths.databaseURL,
      authorizationProvider: authorizationProvider,
      heartbeatStoreURL: resolvedPaths.heartbeatStoreURL,
      personalityProfileURL: resolvedPaths.personalityProfileURL,
      personalMemoryURL: resolvedPaths.personalMemoryURL,
      settingsFileURL: settingsStore == nil ? resolvedPaths.settingsURL : nil,
      inferenceSettingsFileURL: inferenceBackendSettingsStore == nil
        ? resolvedPaths.directoryURL.appendingPathComponent("inference-backends.json") : nil,
      mcpClientSessions: mcpClientSessions,
      mcpServerSettings: settings.mcpServers,
      managedToolLayout: managedToolLayout,
      authorizationMode: settings.authorizationMode,
      connectionAdmissionPolicy: connectionAdmissionPolicy,
      inferenceBackendSettings: inferenceBackendSettings,
      inferenceProviderFactory: inferenceProviderFactory
    )
  }

  /// Returns true when any resident environment key was supplied. This lets the command preserve
  /// the all-explicit developer path while rejecting partial overrides instead of silently mixing
  /// them with persisted settings.
  public static func hasEnvironmentOverride(in environment: [String: String]) -> Bool {
    [
      Self.apiKeyVariable,
      Self.modelVariable,
      Self.workspaceVariable,
      Self.serviceVariable,
      Self.databaseVariable,
      Self.heartbeatStoreVariable,
      Self.heartbeatDatabaseVariable,
      Self.xcodeMCPVariable,
      Self.personalityScopeVariable,
    ].contains { environment[$0] != nil }
  }

  public func makeAuthorizationProvider() -> any OpenAIResponsesAuthorizationProvider {
    openAIAuthorizationProvider
  }

  private static func modelID(
    for settings: HexInferenceBackendSettings,
    fallback: String
  ) -> String {
    switch settings.selectedBackend {
    case .openAIResponses:
      settings.openAI.modelID
    case .mlxLocal:
      settings.mlx.modelID.isEmpty ? fallback : settings.mlx.modelID
    }
  }

  private static func defaultPersonalityScope() -> PersonalMemoryScope {
    PersonalMemoryScope.hex
  }

  private static func makeMCPClientSessions(
    from settings: [HexResidentMCPServerSettings],
    managedToolLayout: MCPManagedToolLayout,
    workspaceRoot: URL,
    secretStore: any HexSecretStore
  ) throws -> [any MCPClientSession] {
    try settings.filter(\.isEnabled).map { setting in
      switch setting.transport {
      case .peekaboo:
        return try MCPDeferredClientSession(serverID: setting.serverID) {
          LocalMCPClientSession(
            configuration: try MCPServerConfiguration.peekaboo(
              layout: managedToolLayout,
              workspaceRoot: workspaceRoot
            )
          )
        }
      case .playwright:
        return try MCPDeferredClientSession(serverID: setting.serverID) {
          LocalMCPClientSession(
            configuration: try MCPServerConfiguration.playwright(
              layout: managedToolLayout,
              workspaceRoot: workspaceRoot
            )
          )
        }
      case .xcode:
        return try MCPDeferredClientSession(serverID: setting.serverID) {
          LocalMCPClientSession(configuration: try MCPServerConfiguration.xcode())
        }
      case .streamableHTTP:
        guard let endpointURL = setting.endpointURL else {
          throw HexGatewayResidentConfigurationError.mcpConfigurationUnavailable
        }
        let headerProvider: any MCPHTTPHeaderProvider =
          setting.requiresBearerToken
          ? try HexMCPSecretHTTPHeaderProvider(
            serverID: setting.serverID, endpointURL: endpointURL, secretStore: secretStore)
          : MCPEmptyHTTPHeaderProvider()
        return StreamableHTTPMCPClientSession(
          configuration: try MCPStreamableHTTPServerConfiguration(
            serverID: setting.serverID,
            endpointURL: endpointURL
          ),
          headerProvider: headerProvider
        )
      case .stdio:
        guard let executableURL = setting.executableURL,
          let workingDirectory = setting.workingDirectory
        else { throw HexGatewayResidentConfigurationError.mcpConfigurationUnavailable }
        return try MCPDeferredClientSession(serverID: setting.serverID) {
          LocalMCPClientSession(
            configuration: try MCPServerConfiguration(
              serverID: setting.serverID, executableURL: executableURL,
              arguments: setting.arguments, workingDirectory: workingDirectory,
              environment: MCPProcessEnvironment.sanitized()))
        }
      }
    }
  }

  private static func value(
    named name: String,
    in environment: [String: String]
  ) -> String? {
    guard let value = environment[name], !value.contains("\0") else {
      return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func isPrintableASCII(_ value: String) -> Bool {
    let bytes = value.utf8
    guard !bytes.isEmpty, bytes.count <= 4_096 else {
      return false
    }
    return bytes.allSatisfy { byte in
      (0x21...0x7E).contains(byte)
    }
  }

  private static func isAbsoluteFileURL(_ url: URL) -> Bool {
    url.isFileURL
      && !url.path.isEmpty
      && url.path.hasPrefix("/")
      && url.path.utf8.count <= 4_096
      && !url.path.contains("\0")
  }

  private static func isValidDataFileURL(_ url: URL) -> Bool {
    let pathComponents = url.path.split(separator: "/", omittingEmptySubsequences: true)
    guard
      Self.isAbsoluteFileURL(url),
      !pathComponents.isEmpty,
      !pathComponents.contains(where: { component in
        component == "." || component == ".."
      })
    else {
      return false
    }

    let standardizedURL = url.standardizedFileURL
    let standardizedComponents = standardizedURL.path.split(
      separator: "/",
      omittingEmptySubsequences: true
    )
    return
      Self.isAbsoluteFileURL(standardizedURL)
      && standardizedURL.path != "/"
      && !standardizedComponents.contains(where: { component in
        component == "." || component == ".."
      })
  }
}
