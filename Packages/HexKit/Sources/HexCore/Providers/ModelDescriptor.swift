/// Provider-reported model metadata. Token counts are expected to be nonnegative and are validated
/// when descriptors enter a runtime/provider boundary.
public struct ModelDescriptor: Codable, Equatable, Sendable {
  public let id: ModelID
  public let providerID: ProviderID
  public let displayName: String
  public let capabilities: Set<InferenceCapability>
  public let contextWindow: Int?
  public let maxOutputTokens: Int?

  public init(
    id: ModelID,
    providerID: ProviderID,
    displayName: String,
    capabilities: Set<InferenceCapability>,
    contextWindow: Int? = nil,
    maxOutputTokens: Int? = nil
  ) {
    self.id = id
    self.providerID = providerID
    self.displayName = displayName
    self.capabilities = capabilities
    self.contextWindow = contextWindow
    self.maxOutputTokens = maxOutputTokens
  }
}
