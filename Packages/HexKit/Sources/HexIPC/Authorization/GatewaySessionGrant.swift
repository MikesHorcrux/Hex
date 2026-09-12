import Foundation
import HexCore

/// An exact grant in one resident lifetime, never a wildcard or a grant after restart.
public struct GatewaySessionGrant: Codable, Hashable, Sendable {
  public let sessionID: UUID
  public let capability: CapabilityID
  public let operation: String
  public let resource: String?

  public init(sessionID: UUID, capability: CapabilityID, operation: String, resource: String?) {
    self.sessionID = sessionID
    self.capability = capability
    self.operation = operation
    self.resource = resource
  }

  public func validated() throws -> Self {
    guard !capability.rawValue.isEmpty, capability.rawValue.utf8.count <= 256,
      !operation.isEmpty, operation.utf8.count <= 256,
      (resource?.utf8.count ?? 0) <= 16_384
    else {
      throw GatewayFailure(code: .malformedPayload, message: "The saved approval scope is invalid.")
    }
    return self
  }
}
