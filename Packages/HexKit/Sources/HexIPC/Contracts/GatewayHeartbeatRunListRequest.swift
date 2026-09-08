import Foundation

public struct GatewayHeartbeatRunListRequest: Codable, Equatable, Sendable {
  public let scheduleID: UUID?
  public let cursor: GatewayHeartbeatRunCursor?
  public let limit: Int

  public init(scheduleID: UUID? = nil, cursor: GatewayHeartbeatRunCursor? = nil, limit: Int = 20) {
    self.scheduleID = scheduleID
    self.cursor = cursor
    self.limit = limit
  }

  public func validated() throws -> Self {
    if let scheduleID { try GatewayRunRecoveryValidation.identity(scheduleID) }
    guard (1...64).contains(limit) else {
      throw GatewayFailure(
        code: .malformedPayload, message: "The scheduled run page limit is invalid.")
    }
    if let cursor {
      _ = try cursor.validated()
      guard cursor.scheduleID == scheduleID else {
        throw GatewayFailure(
          code: .invalidCursor, message: "The scheduled run cursor scope changed.")
      }
    }
    return self
  }
}
