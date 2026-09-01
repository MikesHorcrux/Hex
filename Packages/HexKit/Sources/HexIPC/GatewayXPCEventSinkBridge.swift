@preconcurrency import Foundation

/// Serializes calls to an Objective-C XPC callback object behind an actor. The gateway event task
/// therefore never captures a non-Sendable proxy while crossing a Swift concurrency boundary.
public actor GatewayXPCEventSinkBridge {
  private let sink: any HexGatewayXPCEventSinkProtocol

  public init(sink: sending any HexGatewayXPCEventSinkProtocol) {
    self.sink = sink
  }

  public func receiveEvent(_ envelope: Data) {
    sink.receiveEvent(envelope)
  }

  public func finish(_ response: Data) {
    sink.finish(response)
  }
}
