import Foundation

public struct GatewayFailure: Error, LocalizedError, Codable, Equatable, Sendable {
  public let code: GatewayFailureCode
  public let message: String
  public let isRetryable: Bool

  public init(
    code: GatewayFailureCode,
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
