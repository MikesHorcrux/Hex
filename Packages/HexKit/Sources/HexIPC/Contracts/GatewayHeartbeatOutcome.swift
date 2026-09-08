import Foundation

/// A redacted, bounded summary of the most recent heartbeat outcome. Lease and occurrence
/// identities remain resident-only; the app receives only the information needed to render status.
public struct GatewayHeartbeatOutcome: Codable, Equatable, Sendable {
  public let kind: GatewayHeartbeatOutcomeKind
  public let completedAt: Date
  public let failureMessage: String?

  public init(
    kind: GatewayHeartbeatOutcomeKind,
    completedAt: Date,
    failureMessage: String? = nil
  ) {
    self.kind = kind
    self.completedAt = completedAt
    self.failureMessage = failureMessage
  }

  public func validated() throws -> Self {
    guard completedAt.timeIntervalSinceReferenceDate.isFinite else {
      throw GatewayFailure(
        code: .malformedPayload,
        message: "A heartbeat outcome must contain a finite completion date."
      )
    }
    if let failureMessage {
      guard !failureMessage.isEmpty,
        failureMessage.utf8.count <= Self.maximumFailureMessageBytes
      else {
        throw GatewayFailure(
          code: .malformedPayload,
          message:
            "A heartbeat failure message must contain between 1 and \(Self.maximumFailureMessageBytes) UTF-8 bytes."
        )
      }
    }
    return self
  }

  public static let maximumFailureMessageBytes = 4 * 1_024
}
