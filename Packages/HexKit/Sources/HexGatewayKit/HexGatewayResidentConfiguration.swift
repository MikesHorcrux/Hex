import Foundation
import HexIPC

/// Explicit environment configuration for the headless resident gateway. Secrets are retained only
/// in this process-scoped value and are intentionally absent from equality, descriptions, and
/// diagnostics. A future `SMAppService` launch path must provision credentials through a durable
/// user-controlled channel; this type deliberately does not place secrets in a launch-agent plist.
public struct HexGatewayResidentConfiguration: Sendable {
  public enum ConfigurationError: Swift.Error, Equatable, LocalizedError, Sendable {
    case missingVariables([String])
    case invalidVariable(String)
    case applicationSupportUnavailable

    public var errorDescription: String? {
      switch self {
      case .missingVariables(let variables):
        "Resident gateway configuration is incomplete. Set \(variables.joined(separator: ", "))."
      case .invalidVariable(let variable):
        "The \(variable) resident gateway setting is invalid."
      case .applicationSupportUnavailable:
        "Hex could not locate Application Support for the resident gateway journal."
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
  private let apiKey: String

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
      guard let applicationSupport = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first else {
        throw ConfigurationError.applicationSupportUnavailable
      }
      databaseURL = applicationSupport
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

  public init(
    machServiceName: String,
    modelID: String,
    workspaceRoot: URL,
    databaseURL: URL,
    apiKey: String,
    heartbeatStoreURL: URL? = nil,
    connectionAdmissionPolicy: HexGatewayConnectionAdmissionPolicy = .production()
  ) throws {
    guard Self.isPrintableASCII(machServiceName), machServiceName.utf8.count <= 256 else {
      throw ConfigurationError.invalidVariable(Self.serviceVariable)
    }
    guard Self.isPrintableASCII(modelID), modelID.utf8.count <= 512 else {
      throw ConfigurationError.invalidVariable(Self.modelVariable)
    }
    guard Self.isPrintableASCII(apiKey) else {
      throw ConfigurationError.invalidVariable(Self.apiKeyVariable)
    }
    guard Self.isAbsoluteFileURL(workspaceRoot) else {
      throw ConfigurationError.invalidVariable(Self.workspaceVariable)
    }
    guard Self.isAbsoluteFileURL(databaseURL), databaseURL.lastPathComponent != "." else {
      throw ConfigurationError.invalidVariable(Self.databaseVariable)
    }
    let resolvedHeartbeatStoreURL = heartbeatStoreURL
      ?? databaseURL.deletingLastPathComponent()
        .appendingPathComponent("heartbeats.json", isDirectory: false)
    guard
      Self.isAbsoluteFileURL(resolvedHeartbeatStoreURL),
      resolvedHeartbeatStoreURL.lastPathComponent != "."
    else {
      throw ConfigurationError.invalidVariable(Self.heartbeatStoreVariable)
    }

    self.machServiceName = machServiceName
    self.modelID = modelID
    self.workspaceRoot = workspaceRoot.standardizedFileURL
    self.databaseURL = databaseURL.standardizedFileURL
    self.heartbeatStoreURL = resolvedHeartbeatStoreURL.standardizedFileURL
    self.connectionAdmissionPolicy = connectionAdmissionPolicy
    self.apiKey = apiKey
  }

  public func makeCredentialProvider() -> HexGatewayMemoryCredentialProvider {
    HexGatewayMemoryCredentialProvider(apiKey: apiKey)
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
    url.isFileURL && url.path.hasPrefix("/") && !url.path.contains("\0")
  }
}
