import Foundation

/// Explicit, process-environment configuration for the temporary developer-only live path.
/// Secrets are retained only in memory and are intentionally absent from all descriptions and
/// diagnostics. The Debug app target is unsandboxed so this explicit workspace path can be opened
/// directly; Release keeps its App Sandbox configuration.
nonisolated struct HexDeveloperConfiguration: Equatable, Sendable {
  private nonisolated static let apiKeyVariable = "HEX_OPENAI_API_KEY"
  private nonisolated static let modelVariable = "HEX_OPENAI_MODEL"
  private nonisolated static let workspaceVariable = "HEX_WORKSPACE_ROOT"
  private nonisolated static let gatewayModeVariable = "HEX_GATEWAY_MODE"
  private nonisolated static let gatewayMachServiceVariable = "HEX_GATEWAY_MACH_SERVICE"
  private nonisolated static let inProcessFallbackVariable = "HEX_ALLOW_IN_PROCESS_FALLBACK"

  let openAIAPIKey: String?
  let openAIModel: String?
  let workspaceRoot: URL?
  let gatewayMode: HexGatewayMode
  let gatewayMachServiceName: String
  let allowsInProcessFallback: Bool

  init(environment: [String: String]) {
    openAIAPIKey = Self.value(named: Self.apiKeyVariable, in: environment)
    openAIModel = Self.value(named: Self.modelVariable, in: environment)
    if let rawWorkspaceRoot = Self.value(named: Self.workspaceVariable, in: environment),
      rawWorkspaceRoot.hasPrefix("/")
    {
      workspaceRoot = URL(fileURLWithPath: rawWorkspaceRoot, isDirectory: true)
        .standardizedFileURL
        .resolvingSymlinksInPath()
    } else {
      workspaceRoot = nil
    }
    gatewayMode =
      HexGatewayMode(
        rawValue: Self.value(named: Self.gatewayModeVariable, in: environment) ?? ""
      ) ?? .residentXPC
    gatewayMachServiceName = Self.gatewayMachServiceName(in: environment)
    allowsInProcessFallback = Self.boolean(
      named: Self.inProcessFallbackVariable,
      in: environment
    )
  }

  /// The UI uses this only to avoid presenting a stale production model when it is running in the
  /// offline preview path. A configured model is always used verbatim by the live client.
  nonisolated var modelIDForInterface: String {
    openAIModel ?? "preview"
  }

  /// XPC remains the route whenever the explicit developer fallback is incomplete, disabled, or
  /// not selected. This makes an accidental missing environment variable fail at connection time
  /// instead of silently moving agent work back into the app process.
  nonisolated var gatewayRoute: HexGatewayRoute {
    guard
      gatewayMode == .developerInProcess,
      allowsInProcessFallback,
      (try? liveValues()) != nil
    else {
      return .residentXPC(machServiceName: gatewayMachServiceName)
    }
    return .developerInProcess
  }

  nonisolated func liveValues() throws -> HexDeveloperConfigurationLiveValues {
    var missing: [String] = []
    if openAIAPIKey == nil {
      missing.append(Self.apiKeyVariable)
    }
    if openAIModel == nil {
      missing.append(Self.modelVariable)
    }
    if workspaceRoot == nil {
      missing.append(Self.workspaceVariable)
    }
    guard missing.isEmpty else {
      throw HexDeveloperConfigurationError.missingVariables(missing)
    }

    guard let apiKey = openAIAPIKey, Self.isPrintableASCII(apiKey) else {
      throw HexDeveloperConfigurationError.invalidVariable(Self.apiKeyVariable)
    }
    guard let modelID = openAIModel,
      Self.isPrintableASCII(modelID),
      modelID.utf8.count <= 512
    else {
      throw HexDeveloperConfigurationError.invalidVariable(Self.modelVariable)
    }
    guard let workspaceRoot,
      workspaceRoot.isFileURL,
      workspaceRoot.path.hasPrefix("/"),
      !workspaceRoot.path.contains("\0")
    else {
      throw HexDeveloperConfigurationError.invalidVariable(Self.workspaceVariable)
    }

    return HexDeveloperConfigurationLiveValues(
      apiKey: apiKey,
      modelID: modelID,
      workspaceRoot: workspaceRoot
    )
  }

  private nonisolated static func value(
    named name: String,
    in environment: [String: String]
  ) -> String? {
    guard let value = environment[name], !value.contains("\0") else {
      return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private nonisolated static func gatewayMachServiceName(
    in environment: [String: String]
  ) -> String {
    guard let value = value(named: gatewayMachServiceVariable, in: environment),
      isValidMachServiceName(value)
    else {
      return HexGatewayRoute.defaultMachServiceName
    }
    return value
  }

  private nonisolated static func boolean(
    named name: String,
    in environment: [String: String]
  ) -> Bool {
    guard let value = value(named: name, in: environment)?.lowercased() else {
      return false
    }
    return value == "1" || value == "true" || value == "yes"
  }

  private nonisolated static func isValidMachServiceName(_ value: String) -> Bool {
    guard value.utf8.count <= 256, !value.contains("/") else {
      return false
    }
    return value.unicodeScalars.allSatisfy { scalar in
      scalar.value >= 0x21 && scalar.value <= 0x7E
    }
  }

  private nonisolated static func isPrintableASCII(_ value: String) -> Bool {
    let bytes = value.utf8
    guard !bytes.isEmpty, bytes.count <= 4_096 else {
      return false
    }
    return bytes.allSatisfy { byte in
      (0x21...0x7E).contains(byte)
    }
  }
}
