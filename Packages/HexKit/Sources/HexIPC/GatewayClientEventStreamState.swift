import HexCore

struct GatewayClientEventStreamState: Sendable {
  let runID: AgentRunID
  let invocationID: GatewayRunInvocationID
  let generationID: GatewayClientConnectionGenerationID
  let continuation: AsyncThrowingStream<GatewayEventEnvelope, any Error>.Continuation
  let task: Task<Void, Never>
}
