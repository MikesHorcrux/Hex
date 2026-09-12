import HexCore

struct GatewayClientEventStreamState: Sendable {
  let runID: AgentRunID
  let invocationID: GatewayRunInvocationID
  let generationID: GatewayClientConnectionGenerationID
  let continuation: GatewayBufferedStreamContinuation<GatewayEventEnvelope>
  let task: Task<Void, Never>
}
