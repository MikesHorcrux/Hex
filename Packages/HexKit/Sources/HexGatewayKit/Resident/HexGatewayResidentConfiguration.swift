import Foundation
import HexCore
import HexIPC
import HexPersistence
import HexProviders

/// Resident gateway composition settings. Credentials are injected as a provider and are never
/// part of this value's persisted, Codable, or diagnostic surface. The `SMAppService` launch path
/// loads non-secret settings from Application Support and credentials from the shared data-protection
/// Keychain; this type deliberately does not place secrets in a launch-agent plist.
public struct HexGatewayResidentConfiguration: Sendable {
  public enum ConfigurationError: Swift.Error, Equatable, LocalizedError, Sendable {
    case missingVariables([String])
    case invalidVariable(String)
    case applicationSupportUnavailable
    case settingsUnavailable
    case credentialsUnavailable

    public var errorDescription: String? {
      switch self {
      case .missingVariables(let variables):
        "Resident gateway configuration is incomplete. Set \(variables.joined(separator: ", "))."
      case .invalidVariable(let variable):
        "The \(variable) resident gateway setting is invalid."
      case .applicationSupportUnavailable:
        "Hex could not locate Application Support for the resident gateway."
      case .settingsUnavailable:
        "Hex resident settings are unavailable or invalid."
      case .credentialsUnavailable:
        "Hex resident credentials are unavailable."
      }
    }
  }

  private static let apiKeyVariable = "HEX_OPENAI_API_KEY"
  private static let modelVariable = "HEX_OPENAI_MODEL"
  private static let workspaceVariable = "HEX_WORKSPACE_ROOT"
  private static let serviceVariable = "HEX_GATEWAY_MACH_SERVICE"
  private static let databaseVariable = "HEX_GATEWAY_DATABASE_URL"
  private static let heartbeatStoreVariable = "HEX_HEARTBEAT_STORE_URL"
  private static let heartbeatDatabaseVariable = "HEX_HEARTBEAT_DATABASE_URL"

  public let machServiceName: String
  public let modelID: String
  public let workspaceRoot: URL
  public let databaseURL: URL
  public let heartbeatStoreURL: URL
  public let connectionAdmissionPolicy: HexGatewayConnectionAdmissionPolicy
  public let credentialProvider: any OpenAICredentialProvider

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
      throw ConfigurationError.missingVariables(missing)
    }
    guard let apiKey, let modelID, let workspace else {
      throw ConfigurationError.missingVariables(missing)
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
        throw ConfigurationError.applicationSupportUnavailable
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

    try self.init(
      machServiceName: machServiceName,
      modelID: modelID,
      workspaceRoot: URL(fileURLWithPath: workspace, isDirectory: true),
      databaseURL: databaseURL,
      apiKey: apiKey,
      heartbeatStoreURL: heartbeatStoreURL,
      connectionAdmissionPolicy: .production()
    )
  }

  /// Creates a configuration around a caller-owned credential provider. The provider is queried
  /// only by the inference provider immediately before a request, so this initializer never needs
  /// to receive or encode a secret value.
  public init(
    machServiceName: String,
    modelID: String,
    workspaceRoot: URL,
    databaseURL: URL,
    credentialProvider: any OpenAICredentialProvider,
    heartbeatStoreURL: URL? = nil,
    connectionAdmissionPolicy: HexGatewayConnectionAdmissionPolicy = .production()
  ) throws {
    guard Self.isPrintableASCII(machServiceName), machServiceName.utf8.count <= 256 else {
      throw ConfigurationError.invalidVariable(Self.serviceVariable)
    }
    guard Self.isPrintableASCII(modelID), modelID.utf8.count <= 512 else {
      throw ConfigurationError.invalidVariable(Self.modelVariable)
    }
    let standardizedWorkspaceRoot = workspaceRoot.standardizedFileURL
    guard
      Self.isAbsoluteFileURL(workspaceRoot),
      Self.isAbsoluteFileURL(standardizedWorkspaceRoot)
    else {
      throw ConfigurationError.invalidVariable(Self.workspaceVariable)
    }
    let standardizedDatabaseURL = databaseURL.standardizedFileURL
    guard
      Self.isValidDataFileURL(databaseURL),
      Self.isValidDataFileURL(standardizedDatabaseURL)
    else {
      throw ConfigurationError.invalidVariable(Self.databaseVariable)
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
      throw ConfigurationError.invalidVariable(Self.heartbeatStoreVariable)
    }

    self.machServiceName = machServiceName
    self.modelID = modelID
    self.workspaceRoot = standardizedWorkspaceRoot
    self.databaseURL = standardizedDatabaseURL
    self.heartbeatStoreURL = standardizedHeartbeatStoreURL
    self.connectionAdmissionPolicy = connectionAdmissionPolicy
    self.credentialProvider = credentialProvider
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
    connectionAdmissionPolicy: HexGatewayConnectionAdmissionPolicy = .production()
  ) throws {
    guard Self.isPrintableASCII(apiKey) else {
      throw ConfigurationError.invalidVariable(Self.apiKeyVariable)
    }
    try self.init(
      machServiceName: machServiceName,
      modelID: modelID,
      workspaceRoot: workspaceRoot,
      databaseURL: databaseURL,
      credentialProvider: HexGatewayMemoryCredentialProvider(apiKey: apiKey),
      heartbeatStoreURL: heartbeatStoreURL,
      connectionAdmissionPolicy: connectionAdmissionPolicy
    )
  }

  /// Loads non-secret settings from the durable store and injects a generic secret store adapter.
  /// The API key is not read during startup; only item existence is checked so a missing credential
  /// fails deterministically before the resident host begins serving requests. Actual credential
  /// decoding and format validation remain deferred to provider use.
  public static func loadPersisted(
    paths: HexResidentDataPaths? = nil,
    settingsStore: (any HexResidentRuntimeSettingsStore)? = nil,
    secretStore: (any HexSecretStore)? = nil,
    connectionAdmissionPolicy: HexGatewayConnectionAdmissionPolicy = .production()
  ) async throws -> Self {
    let resolvedPaths: HexResidentDataPaths
    do {
      resolvedPaths = try paths ?? HexResidentDataPaths.live()
    } catch {
      throw ConfigurationError.applicationSupportUnavailable
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
      throw ConfigurationError.settingsUnavailable
    }

    let settings: HexResidentRuntimeSettings
    do {
      guard let loadedSettings = try await resolvedSettingsStore.load() else {
        throw ConfigurationError.settingsUnavailable
      }
      settings = loadedSettings
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw ConfigurationError.settingsUnavailable
    }

    let resolvedSecretStore: any HexSecretStore = secretStore ?? KeychainHexSecretStore()
    do {
      guard try await resolvedSecretStore.exists(.openAIAPIKey) else {
        throw ConfigurationError.credentialsUnavailable
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as ConfigurationError {
      throw error
    } catch {
      throw ConfigurationError.credentialsUnavailable
    }

    return try Self(
      machServiceName: HexGatewayServiceIdentity.machServiceName,
      modelID: settings.modelID,
      workspaceRoot: settings.workspaceRoot,
      databaseURL: resolvedPaths.databaseURL,
      credentialProvider: HexSecretStoreOpenAICredentialProvider(store: resolvedSecretStore),
      heartbeatStoreURL: resolvedPaths.heartbeatStoreURL,
      connectionAdmissionPolicy: connectionAdmissionPolicy
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
    ].contains { environment[$0] != nil }
  }

  public func makeCredentialProvider() -> any OpenAICredentialProvider {
    credentialProvider
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
