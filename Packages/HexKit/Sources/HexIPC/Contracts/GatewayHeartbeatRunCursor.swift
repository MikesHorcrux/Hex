import Foundation

/// Store-bound keyset cursor. Scope and the fixed high-water cannot change between pages.
public struct GatewayHeartbeatRunCursor: Codable, Equatable, Sendable {
  public let storeID: UUID
  public let scheduleID: UUID?
  public let highWaterSequence: Int64
  public let beforeSequence: Int64

  public init(
    storeID: UUID, scheduleID: UUID?, highWaterSequence: Int64, beforeSequence: Int64
  ) {
    self.storeID = storeID
    self.scheduleID = scheduleID
    self.highWaterSequence = highWaterSequence
    self.beforeSequence = beforeSequence
  }

  public func validated() throws -> Self {
    try GatewayRunRecoveryValidation.identity(storeID)
    if let scheduleID { try GatewayRunRecoveryValidation.identity(scheduleID) }
    guard highWaterSequence > 0, beforeSequence > 0, beforeSequence <= highWaterSequence else {
      throw GatewayFailure(
        code: .invalidCursor, message: "The scheduled run history cursor is invalid.")
    }
    return self
  }
}
