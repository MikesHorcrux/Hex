@preconcurrency import Foundation

final class NativeHexGatewayXPCConnectionEventSink: NSObject, HexGatewayXPCEventSinkProtocol {
  private let receiveEventHandler: @Sendable (Data) -> Bool
  private let finishHandler: @Sendable (Data) -> Void

  init(
    receiveEvent: @escaping @Sendable (Data) -> Bool,
    finish: @escaping @Sendable (Data) -> Void
  ) {
    receiveEventHandler = receiveEvent
    finishHandler = finish
  }

  func receiveEvent(_ envelope: Data, withReply reply: @escaping @Sendable (Bool) -> Void) {
    reply(receiveEventHandler(envelope))
  }

  func finish(_ response: Data) {
    finishHandler(response)
  }
}
