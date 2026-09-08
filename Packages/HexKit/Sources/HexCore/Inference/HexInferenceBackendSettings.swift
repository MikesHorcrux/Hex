/// Persisted, non-secret inference-backend selection and setup.
///
/// This value is safe to encode as JSON. In particular, it has no OpenAI API-key field and no
/// ChatGPT OAuth token field.
public struct HexInferenceBackendSettings: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 2
  public static let defaultOpenAIModelID = "gpt-5.6-luna"

  public let schemaVersion: Int
  public let selectedBackend: HexInferenceBackendKind
  public let openAI: HexOpenAIBackendSettings
  public let mlx: HexMLXBackendSettings

  public init(
    selectedBackend: HexInferenceBackendKind,
    openAI: HexOpenAIBackendSettings,
    mlx: HexMLXBackendSettings,
    schemaVersion: Int = Self.currentSchemaVersion
  ) throws {
    guard schemaVersion == Self.currentSchemaVersion else {
      throw HexInferenceBackendSettingsError.unsupportedSchemaVersion(schemaVersion)
    }
    self.schemaVersion = schemaVersion
    self.selectedBackend = selectedBackend
    self.openAI = openAI
    self.mlx = mlx
  }

  public init(
    selectedBackend: HexInferenceBackendKind = .openAIResponses,
    openAIModelID: String = Self.defaultOpenAIModelID,
    openAIAuthenticationMethod: HexOpenAIAuthenticationMethod = .apiKey,
    mlx: HexMLXBackendSettings? = nil
  ) throws {
    try self.init(
      selectedBackend: selectedBackend,
      openAI: HexOpenAIBackendSettings(
        modelID: openAIModelID,
        authenticationMethod: openAIAuthenticationMethod
      ),
      mlx: mlx ?? HexMLXBackendSettings()
    )
  }

  /// Explicitly migrates the legacy resident model setting into the backend-selection document.
  /// A missing legacy value uses the stable OpenAI default so an absent backend document preserves
  /// the pre-selection resident behavior without selecting another provider implicitly.
  public static func migrationDefault(legacyOpenAIModelID: String? = nil) throws -> Self {
    try Self(
      selectedBackend: .openAIResponses,
      openAIModelID: legacyOpenAIModelID ?? Self.defaultOpenAIModelID
    )
  }

  public var selectedBackendIsConfigured: Bool {
    switch selectedBackend {
    case .openAIResponses:
      true
    case .mlxLocal:
      mlx.isConfigured
    }
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case selectedBackend
    case openAI
    case mlx
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedSchemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    guard decodedSchemaVersion == 1 || decodedSchemaVersion == Self.currentSchemaVersion else {
      throw HexInferenceBackendSettingsError.unsupportedSchemaVersion(decodedSchemaVersion)
    }
    let rawSelectedBackend = try container.decode(String.self, forKey: .selectedBackend)
    let decodedOpenAI = try container.decode(HexOpenAIBackendSettings.self, forKey: .openAI)
    let selectedBackend: HexInferenceBackendKind
    let openAI: HexOpenAIBackendSettings
    if rawSelectedBackend == "codex-compatibility" {
      selectedBackend = .openAIResponses
      openAI = try HexOpenAIBackendSettings(
        modelID: decodedOpenAI.modelID,
        authenticationMethod: .chatGPT
      )
    } else if let backend = HexInferenceBackendKind(rawValue: rawSelectedBackend) {
      selectedBackend = backend
      openAI = decodedOpenAI
    } else {
      throw DecodingError.dataCorruptedError(
        forKey: .selectedBackend,
        in: container,
        debugDescription: "Unknown inference backend."
      )
    }
    try self.init(
      selectedBackend: selectedBackend,
      openAI: openAI,
      mlx: container.decode(HexMLXBackendSettings.self, forKey: .mlx),
      schemaVersion: Self.currentSchemaVersion
    )
  }
}
