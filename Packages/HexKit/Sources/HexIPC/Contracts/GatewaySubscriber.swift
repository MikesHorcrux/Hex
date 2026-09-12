import HexCore

struct GatewaySubscriber: Sendable {
  let sessionID: GatewaySessionID
  let continuation: GatewayBufferedStreamContinuation<GatewayEventEnvelope>
}
