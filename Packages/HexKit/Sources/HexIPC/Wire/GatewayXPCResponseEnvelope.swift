import Foundation

/// A bounded XPC reply. Exactly one of `body` and `failure` is present for a successful or failed
/// operation respectively. Event-stream completion uses the same shape with a nil body and no
/// failure.
public struct GatewayXPCResponseEnvelope: Codable, Equatable, Sendable {
  public let operation: GatewayXPCOperation
  public let body: Data?
  public let failure: GatewayFailure?

  public init(
    operation: GatewayXPCOperation,
    body: Data?
  ) {
    self.operation = operation
    self.body = body
    failure = nil
  }

  public init(
    operation: GatewayXPCOperation,
    failure: GatewayFailure
  ) {
    self.operation = operation
    body = nil
    self.failure = failure
  }

  public func validated() throws -> GatewayXPCResponseEnvelope {
    switch (body, failure) {
    case (.some, .none), (.none, .some), (.none, .none):
      return self
    case (.some, .some):
      throw GatewayFailure(
        code: .malformedPayload,
        message: "The gateway XPC reply contained both a result and a failure."
      )
    }
  }
}
