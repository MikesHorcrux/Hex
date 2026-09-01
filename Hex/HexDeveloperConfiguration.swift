import Foundation

/// Explicit, process-environment configuration for the temporary developer-only live path.
/// Secrets are retained only in memory and are intentionally absent from all descriptions and
/// diagnostics.
nonisolated struct HexDeveloperConfiguration: Equatable, Sendable {
  struct LiveValues: Equatable, Sendable {
    let apiKey: String
    let modelID: String
    let workspaceRoot: URL
  }

  enum ConfigurationError: Error, Equatable, LocalizedError, Sendable {
    case missingVariables([String])
    case invalidVariable(String)

    var errorDescription: String? {
      switch self {
      case .missingVariables(let variables):
        return
          "Live developer mode is not configured. Set \(variables.joined(separator: ", ")) before running Hex."
      case .invalidVariable(let variable):
        return "The \(variable) developer setting is invalid. Check its value and try again."
      }
    }
  }

  private nonisolated static let apiKeyVariable = "HEX_OPENAI_API_KEY"
  private nonisolated static let modelVariable = "HEX_OPENAI_MODEL"
  private nonisolated static let workspaceVariable = "HEX_WORKSPACE_ROOT"

  let openAIAPIKey: String?
  let openAIModel: String?
  let workspaceRoot: URL?

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
  }

  /// The UI uses this only to avoid presenting a stale production model when it is running in the
  /// offline preview path. A configured model is always used verbatim by the live client.
  nonisolated var modelIDForInterface: String {
    openAIModel ?? "preview"
  }

  nonisolated func liveValues() throws -> LiveValues {
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
      throw ConfigurationError.missingVariables(missing)
    }

    guard let apiKey = openAIAPIKey, Self.isPrintableASCII(apiKey) else {
      throw ConfigurationError.invalidVariable(Self.apiKeyVariable)
    }
    guard let modelID = openAIModel,
      Self.isPrintableASCII(modelID),
      modelID.utf8.count <= 512
    else {
      throw ConfigurationError.invalidVariable(Self.modelVariable)
    }
    guard let workspaceRoot,
      workspaceRoot.isFileURL,
      workspaceRoot.path.hasPrefix("/"),
      !workspaceRoot.path.contains("\0")
    else {
      throw ConfigurationError.invalidVariable(Self.workspaceVariable)
    }

    return LiveValues(
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
