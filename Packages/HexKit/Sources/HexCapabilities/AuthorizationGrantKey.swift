import HexCore

/// Exact-match authority. `resource == nil` deliberately represents the whole operation rather
/// than acting as a wildcard for resource-specific grants.
public struct AuthorizationGrantKey: Codable, Equatable, Hashable, Sendable {
  public let capability: CapabilityID
  public let operation: String
  public let resource: String?

  public init(
    capability: CapabilityID,
    operation: String,
    resource: String?
  ) {
    self.capability = capability
    self.operation = operation
    self.resource = resource
  }

  public init(request: AuthorizationRequest) {
    self.init(
      capability: request.capability,
      operation: request.operation,
      resource: request.resource
    )
  }
}
