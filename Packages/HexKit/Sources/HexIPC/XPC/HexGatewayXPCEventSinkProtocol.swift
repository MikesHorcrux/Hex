import Foundation

/// Objective-C-compatible callback object exported by the XPC client for one event subscription.
/// Version 1.12 acknowledges bounded admission before the service sends another event. This is
/// transport credit, not an acknowledgement that the app applied or durably saved the event.
@preconcurrency @objc public protocol HexGatewayXPCEventSinkProtocol: Sendable {
  func receiveEvent(_ envelope: Data, withReply reply: @escaping @Sendable (Bool) -> Void)
  func finish(_ response: Data)
}
