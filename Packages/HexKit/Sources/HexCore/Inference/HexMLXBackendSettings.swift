import Foundation

/// Non-secret settings for a local MLX model already present on disk.
///
/// An empty value is allowed for an unconfigured backend so the settings document can be created
/// before the user chooses a model. A configured value still requires all of `modelID`,
/// `displayName`, and `directory`.
public struct HexMLXBackendSettings: Codable, Equatable, Sendable {
  public let modelID: String
  public let displayName: String
  public let directory: URL?
  public let contextWindow: Int?
  public let maximumOutputTokens: Int
  public let supportsToolCalling: Bool
  public let supportsParallelToolCalling: Bool

  public init(
    modelID: String = "",
    displayName: String = "",
    directory: URL? = nil,
    contextWindow: Int? = nil,
    maximumOutputTokens: Int = 2_048,
    supportsToolCalling: Bool = false,
    supportsParallelToolCalling: Bool = false
  ) throws {
    let isEmptyConfiguration = modelID.isEmpty && displayName.isEmpty && directory == nil
    guard isEmptyConfiguration || Self.isValidIdentifier(modelID) else {
      throw HexInferenceBackendSettingsError.invalidMLXModelID
    }
    guard isEmptyConfiguration || Self.isValidDisplayName(displayName) else {
      throw HexInferenceBackendSettingsError.invalidMLXDisplayName
    }
    if let directory {
      guard Self.isValidAbsoluteFileURL(directory) else {
        throw HexInferenceBackendSettingsError.invalidMLXDirectory
      }
    }
    guard (1...1_000_000).contains(maximumOutputTokens) else {
      throw HexInferenceBackendSettingsError.invalidMLXOutputTokens
    }
    if let contextWindow {
      guard (1...1_000_000).contains(contextWindow), maximumOutputTokens <= contextWindow else {
        throw HexInferenceBackendSettingsError.invalidMLXContextWindow
      }
    }
    guard !supportsParallelToolCalling || supportsToolCalling else {
      throw HexInferenceBackendSettingsError.invalidMLXContextWindow
    }

    self.modelID = modelID
    self.displayName = displayName
    self.directory = directory?.standardizedFileURL
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
      directory: container.decodeIfPresent(URL.self, forKey: .directory),
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
    !modelID.isEmpty && !displayName.isEmpty && directory != nil
  }

  private enum CodingKeys: String, CodingKey {
    case modelID
    case displayName
    case directory
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

  private static func isValidAbsoluteFileURL(_ url: URL) -> Bool {
    let path = url.path
    return url.isFileURL
      && !path.isEmpty
      && path != "/"
      && path.hasPrefix("/")
      && path.utf8.count <= 4_096
      && !path.contains("\0")
  }
}
