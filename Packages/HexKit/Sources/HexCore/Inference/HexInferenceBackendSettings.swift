/// Persisted, non-secret inference-backend selection and setup.
///
/// This value is safe to encode as JSON. In particular, it has no OpenAI API-key field and no
/// ChatGPT/Codex token field. Codex account credentials remain owned by the Codex app-server.
public struct HexInferenceBackendSettings: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1
  public static let defaultOpenAIModelID = "gpt-5.2"

  public let schemaVersion: Int
  public let selectedBackend: HexInferenceBackendKind
  public let openAI: HexOpenAIBackendSettings
  public let mlx: HexMLXBackendSettings
  public let codex: HexCodexCompatibilitySettings

  public init(
    selectedBackend: HexInferenceBackendKind,
    openAI: HexOpenAIBackendSettings,
    mlx: HexMLXBackendSettings,
    codex: HexCodexCompatibilitySettings,
    schemaVersion: Int = Self.currentSchemaVersion
  ) throws {
    guard schemaVersion == Self.currentSchemaVersion else {
      throw HexInferenceBackendSettingsError.unsupportedSchemaVersion(schemaVersion)
    }
    self.schemaVersion = schemaVersion
    self.selectedBackend = selectedBackend
    self.openAI = openAI
    self.mlx = mlx
    self.codex = codex
  }

  public init(
    selectedBackend: HexInferenceBackendKind = .openAIResponses,
    openAIModelID: String = Self.defaultOpenAIModelID,
    mlx: HexMLXBackendSettings? = nil,
    codex: HexCodexCompatibilitySettings? = nil
  ) throws {
    try self.init(
      selectedBackend: selectedBackend,
      openAI: HexOpenAIBackendSettings(modelID: openAIModelID),
      mlx: mlx ?? HexMLXBackendSettings(),
      codex: codex ?? HexCodexCompatibilitySettings()
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
    case .codexCompatibility:
      codex.isConfigured
    }
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case selectedBackend
    case openAI
    case mlx
    case codex
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      selectedBackend: container.decode(HexInferenceBackendKind.self, forKey: .selectedBackend),
      openAI: container.decode(HexOpenAIBackendSettings.self, forKey: .openAI),
      mlx: container.decode(HexMLXBackendSettings.self, forKey: .mlx),
      codex: container.decode(HexCodexCompatibilitySettings.self, forKey: .codex),
      schemaVersion: container.decode(Int.self, forKey: .schemaVersion)
    )
  }
}
