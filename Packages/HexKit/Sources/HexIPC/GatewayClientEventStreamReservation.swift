import HexCore

struct GatewayClientEventStreamReservation: Sendable {
  let runID: AgentRunID
  let invocationID: GatewayRunInvocationID
  let generationID: GatewayClientConnectionGenerationID
  let lease: GatewayTransportConnectionLease
  let cancellationState: GatewayClientEventStreamCancellationState
}
