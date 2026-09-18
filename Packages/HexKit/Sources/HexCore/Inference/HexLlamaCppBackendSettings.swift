import Foundation

/// Non-secret settings for a local GGUF model served by Prism's llama.cpp server.
public struct HexLlamaCppBackendSettings: Codable, Equatable, Sendable {
  public let modelID: String
  public let displayName: String
  public let endpoint: URL?
  public let contextWindow: Int?
  public let maximumOutputTokens: Int
  public let supportsToolCalling: Bool
  public let supportsParallelToolCalling: Bool

  public init(
    modelID: String = "",
    displayName: String = "",
    endpoint: URL? = nil,
    contextWindow: Int? = nil,
    maximumOutputTokens: Int = 2_048,
    supportsToolCalling: Bool = false,
    supportsParallelToolCalling: Bool = false
  ) throws {
    let isEmptyConfiguration = modelID.isEmpty && displayName.isEmpty && endpoint == nil
    guard isEmptyConfiguration || Self.isValidIdentifier(modelID) else {
      throw HexInferenceBackendSettingsError.invalidLlamaModelID
    }
    guard isEmptyConfiguration || Self.isValidDisplayName(displayName) else {
      throw HexInferenceBackendSettingsError.invalidLlamaDisplayName
    }
    if let endpoint {
      guard Self.isValidEndpoint(endpoint) else {
        throw HexInferenceBackendSettingsError.invalidLlamaEndpoint
      }
    }
    guard (1...1_000_000).contains(maximumOutputTokens) else {
      throw HexInferenceBackendSettingsError.invalidLlamaOutputTokens
    }
    if let contextWindow {
      guard (1...1_000_000).contains(contextWindow), maximumOutputTokens <= contextWindow else {
        throw HexInferenceBackendSettingsError.invalidLlamaContextWindow
      }
    }
    guard !supportsParallelToolCalling || supportsToolCalling else {
      throw HexInferenceBackendSettingsError.invalidLlamaContextWindow
    }

    self.modelID = modelID
    self.displayName = displayName
    self.endpoint = endpoint
    self.contextWindow = contextWindow
    self.maximumOutputTokens = maximumOutputTokens
    self.supportsToolCalling = supportsToolCalling
    self.supportsParallelToolCalling = supportsParallelToolCalling
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      modelID: container.decode(String.self, forKey: .modelID),
      displayName: container.decode(String.self, forKey: .displayName),
      endpoint: container.decodeIfPresent(URL.self, forKey: .endpoint),
      contextWindow: container.decodeIfPresent(Int.self, forKey: .contextWindow),
      maximumOutputTokens: container.decode(Int.self, forKey: .maximumOutputTokens),
      supportsToolCalling: container.decode(Bool.self, forKey: .supportsToolCalling),
      supportsParallelToolCalling: container.decode(
        Bool.self,
        forKey: .supportsParallelToolCalling
      )
    )
  }

  public var isConfigured: Bool {
    !modelID.isEmpty && !displayName.isEmpty && endpoint != nil
  }

  private enum CodingKeys: String, CodingKey {
    case modelID
    case displayName
    case endpoint
    case contextWindow
    case maximumOutputTokens
    case supportsToolCalling
    case supportsParallelToolCalling
  }

  private static func isValidIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 256 && !value.contains("\0")
  }

  private static func isValidDisplayName(_ value: String) -> Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && value.utf8.count <= 512
      && !value.contains("\0")
  }

  private static func isValidEndpoint(_ url: URL) -> Bool {
    guard
      let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = url.host, !host.isEmpty,
      url.user == nil, url.password == nil,
      url.fragment == nil,
      url.absoluteString.utf8.count <= 4_096,
      !url.absoluteString.contains("\0")
    else { return false }
    return true
  }
}
