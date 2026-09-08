import Foundation

/// The Data-only Objective-C protocol spoken over a local NSXPCConnection. The protocol deliberately
/// carries no Hex model classes: all values are bounded Codable envelopes validated independently at
/// each process boundary.
@preconcurrency @objc public protocol HexGatewayXPCServiceProtocol {
  func request(_ envelope: Data, withReply reply: @escaping @Sendable (Data) -> Void)

  func subscribe(
    _ envelope: Data,
    sink: HexGatewayXPCEventSinkProtocol,
    withReply reply: @escaping @Sendable (Data) -> Void
  )
}
