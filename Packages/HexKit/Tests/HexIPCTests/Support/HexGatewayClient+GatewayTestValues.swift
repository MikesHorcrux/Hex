import HexCore
import HexIPC

extension HexGatewayClient {
  func acknowledge(
    _ record: AgentEventRecord,
    invocationID: GatewayRunInvocationID
  ) throws {
    try acknowledge(GatewayEventEnvelope(invocationID: invocationID, record: record))
  }

  func shouldApply(
    _ record: AgentEventRecord,
    invocationID: GatewayRunInvocationID
  ) throws -> Bool {
    try shouldApply(GatewayEventEnvelope(invocationID: invocationID, record: record))
  }
}
