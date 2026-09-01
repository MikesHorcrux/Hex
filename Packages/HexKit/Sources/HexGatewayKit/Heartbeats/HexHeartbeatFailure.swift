import Foundation

public struct HexHeartbeatFailure: Codable, Equatable, Sendable {
  public let code: HexHeartbeatFailureCode
  public let message: String
  public let retryable: Bool

  public init(
    code: HexHeartbeatFailureCode,
    message: String,
    retryable: Bool = false
  ) {
    self.code = code
    self.message = message
    self.retryable = retryable
  }
}
