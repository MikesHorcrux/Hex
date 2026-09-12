import CryptoKit
import Foundation

/// A secret identifier, never its value. Existing provider identifiers retain their wire format.
public struct HexSecretKey: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String

  public static let openAIAPIKey = Self(validatedValue: "openai-api-key")
  public static let openAIChatGPTOAuth = Self(validatedValue: "openai-chatgpt-oauth")

  public init?(rawValue: String) {
    let suffix = rawValue.dropFirst("mcp-bearer-".count)
    guard
      rawValue == "openai-api-key" || rawValue == "openai-chatgpt-oauth"
        || (rawValue.hasPrefix("mcp-bearer-") && suffix.count == 64
          && suffix.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
    else { return nil }
    self.rawValue = rawValue
  }

  /// Exact endpoint binding prevents a changed server address from receiving an existing token.
  public static func mcpBearerToken(serverID: String, endpointURL: URL) throws -> Self {
    _ = try HexResidentMCPServerSettings(
      serverID: serverID, transport: .streamableHTTP, endpointURL: endpointURL)
    let identity = Data("\(serverID)\0\(endpointURL.absoluteString)".utf8)
    let digest = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    return Self(validatedValue: "mcp-bearer-\(digest)")
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    guard let key = Self(rawValue: value) else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid secret key.")
    }
    self = key
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  private init(validatedValue: String) { rawValue = validatedValue }
}
