/// Non-secret settings for OpenAI Responses API inference.
///
/// The API key is intentionally absent. It belongs to `HexSecretStore` and is requested only at
/// the provider boundary immediately before a request is made.
public struct HexOpenAIBackendSettings: Codable, Equatable, Sendable {
  public let modelID: String

  public init(modelID: String) throws {
    guard Self.isValidIdentifier(modelID) else {
      throw HexInferenceBackendSettingsError.invalidOpenAIModelID
    }
    self.modelID = modelID
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(modelID: container.decode(String.self, forKey: .modelID))
  }

  private enum CodingKeys: String, CodingKey {
    case modelID
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
