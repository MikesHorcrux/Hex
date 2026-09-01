import Foundation

public protocol HexHeartbeatSleeper: Sendable {
  /// A nil date means no schedule is currently due. Implementations should remain cancellable so
  /// schedule edits can wake a resident loop without polling or inference.
  func sleep(until date: Date?) async throws
}
