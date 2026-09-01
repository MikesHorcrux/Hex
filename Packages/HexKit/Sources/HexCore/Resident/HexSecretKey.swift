/// Stable identifiers for secrets owned by Hex. Secret values never cross this enum boundary.
public enum HexSecretKey: String, Codable, Equatable, Sendable {
  case openAIAPIKey = "openai-api-key"
}
