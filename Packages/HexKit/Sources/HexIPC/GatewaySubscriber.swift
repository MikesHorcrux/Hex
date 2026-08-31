import HexCore

struct GatewaySubscriber: Sendable {
  let sessionID: GatewaySessionID
  let continuation: AsyncThrowingStream<GatewayEventEnvelope, any Error>.Continuation
}
