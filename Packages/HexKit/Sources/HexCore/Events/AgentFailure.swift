import Foundation

/// Stable, serializable failure data. It deliberately never retains an arbitrary `Error`, which may
/// contain credentials, non-Sendable state, or process-local implementation details.
public struct AgentFailure: Error, LocalizedError, Codable, Equatable, Sendable {
  public let code: AgentFailureCode
  public let message: String
  public let isRetryable: Bool

  public init(
    code: AgentFailureCode,
    message: String,
    isRetryable: Bool = false
  ) {
    self.code = code
    self.message = message
    self.isRetryable = isRetryable
  }

  public var errorDescription: String? {
    message
  }
}
