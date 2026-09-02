/// Non-secret settings for OpenAI inference.
///
/// API keys and ChatGPT OAuth tokens are intentionally absent. They belong to `HexSecretStore` and
/// are requested only at the provider boundary immediately before a request is made.
public struct HexOpenAIBackendSettings: Codable, Equatable, Sendable {
  public let modelID: String
  public let authenticationMethod: HexOpenAIAuthenticationMethod

  public init(
    modelID: String,
    authenticationMethod: HexOpenAIAuthenticationMethod = .apiKey
  ) throws {
    guard Self.isValidIdentifier(modelID) else {
      throw HexInferenceBackendSettingsError.invalidOpenAIModelID
    }
    self.modelID = modelID
    self.authenticationMethod = authenticationMethod
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      modelID: container.decode(String.self, forKey: .modelID),
      authenticationMethod: try container.decodeIfPresent(
        HexOpenAIAuthenticationMethod.self,
        forKey: .authenticationMethod
      ) ?? .apiKey
    )
  }

  private enum CodingKeys: String, CodingKey {
    case modelID
    case authenticationMethod
  }

  private static func isValidIdentifier(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 512 else {
      return false
    }
    return value.utf8.allSatisfy { byte in
      (0x21...0x7E).contains(byte)
    }
  }
}
