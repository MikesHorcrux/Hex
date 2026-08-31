public struct ProviderDescriptor: Codable, Equatable, Sendable {
  public let id: ProviderID
  public let displayName: String
  public let capabilities: Set<InferenceCapability>

  public init(
    id: ProviderID,
    displayName: String,
    capabilities: Set<InferenceCapability>
  ) {
    self.id = id
    self.displayName = displayName
    self.capabilities = capabilities
  }
}
