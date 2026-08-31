import HexCore

struct GatewayClientEventStreamState: Sendable {
  let generationID: GatewayClientConnectionGenerationID
  let continuation: AsyncThrowingStream<AgentEventRecord, any Error>.Continuation
  let task: Task<Void, Never>
}
