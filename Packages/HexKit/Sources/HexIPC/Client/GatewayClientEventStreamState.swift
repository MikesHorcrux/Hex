import HexCore

struct GatewayClientEventStreamState: Sendable {
  let runID: AgentRunID
  let invocationID: GatewayRunInvocationID
  let generationID: GatewayClientConnectionGenerationID
  let continuation: GatewayBufferedStream<GatewayEventEnvelope>.Continuation
  let task: Task<Void, Never>
}
