import HexCore

struct GatewaySubscriber: Sendable {
  let sessionID: GatewaySessionID
  let continuation: AsyncThrowingStream<AgentEventRecord, any Error>.Continuation
}
