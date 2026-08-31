/// Optional provider controls. When present, `maxOutputTokens` is expected to be nonnegative;
/// runtime/provider boundaries validate values against model-specific limits.
public struct InferenceOptions: Codable, Equatable, Sendable {
  public let maxOutputTokens: Int?
  public let temperature: Double?

  public init(
    maxOutputTokens: Int? = nil,
    temperature: Double? = nil
  ) {
    self.maxOutputTokens = maxOutputTokens
    self.temperature = temperature
  }
}
