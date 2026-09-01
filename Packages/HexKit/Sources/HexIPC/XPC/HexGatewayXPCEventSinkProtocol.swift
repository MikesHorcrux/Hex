import Foundation

/// Objective-C-compatible callback object exported by the XPC client for one event subscription.
/// Callbacks are one-way; the client applies its own bounded buffering and reports cancellation to
/// the service through a normal request envelope.
@preconcurrency @objc public protocol HexGatewayXPCEventSinkProtocol: Sendable {
  func receiveEvent(_ envelope: Data)
  func finish(_ response: Data)
}
