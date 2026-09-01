/// Stable identifiers for secrets owned by Hex. This type identifies a secret without carrying its
/// value through settings, persistence metadata, or diagnostics.
public enum HexSecretKey: String, Codable, Equatable, Sendable {
  case openAIAPIKey = "openai-api-key"
}
