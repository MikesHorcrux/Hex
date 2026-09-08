import HexCore

struct GatewaySubscriber: Sendable {
  let sessionID: GatewaySessionID
  let continuation: GatewayBufferedStream<GatewayEventEnvelope>.Continuation
}
