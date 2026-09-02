import Foundation

/// A bounded identity-only heartbeat mutation request.
public struct GatewayHeartbeatScheduleMutation: Codable, Equatable, Sendable {
  public let scheduleID: UUID

  public init(scheduleID: UUID) {
    self.scheduleID = scheduleID
  }

  public func validated() throws -> Self {
    guard scheduleID != GatewayHeartbeatSchedule.zeroUUID else {
      throw GatewayFailure(
        code: .malformedPayload,
        message: "A heartbeat mutation must contain a non-zero schedule identity."
      )
    }
    return self
  }
}
