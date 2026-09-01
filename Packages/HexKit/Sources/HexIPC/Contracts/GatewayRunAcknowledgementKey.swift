import HexCore

struct GatewayRunAcknowledgementKey: Hashable, Sendable {
  let runID: AgentRunID
  let invocationID: GatewayRunInvocationID
}
