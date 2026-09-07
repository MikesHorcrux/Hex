import Foundation
import HexCore

/// Only live resident waiters are actionable. Historical requests remain in the event journal.
public struct GatewayApprovalInbox: Codable, Equatable, Sendable {
  public let requests: [AuthorizationRequest]
  public let sessionGrants: [GatewaySessionGrant]
  public let defaultMode: HexAuthorizationMode

  public init(
    requests: [AuthorizationRequest] = [], sessionGrants: [GatewaySessionGrant] = [],
    defaultMode: HexAuthorizationMode = .askEveryTime
  ) {
    self.requests = requests
    self.sessionGrants = sessionGrants
    self.defaultMode = defaultMode
  }

  public func validated() throws -> Self {
    guard requests.count <= 128, sessionGrants.count <= 1_024,
      Set(requests.map(\.id)).count == requests.count,
      Set(sessionGrants).count == sessionGrants.count
    else {
      throw GatewayFailure(
        code: .malformedPayload, message: "The approval inbox is invalid or too large.")
    }
    for request in requests {
      guard !request.capability.rawValue.isEmpty, request.capability.rawValue.utf8.count <= 256,
        !request.operation.isEmpty, request.operation.utf8.count <= 256,
        (request.resource?.utf8.count ?? 0) <= 16_384,
        request.explanation.utf8.count <= 16_384,
        try JSONEncoder().encode(request.details).count <= 65_536
      else {
        throw GatewayFailure(code: .malformedPayload, message: "A pending approval is invalid.")
      }
    }
    for grant in sessionGrants { _ = try grant.validated() }
    return self
  }
}
