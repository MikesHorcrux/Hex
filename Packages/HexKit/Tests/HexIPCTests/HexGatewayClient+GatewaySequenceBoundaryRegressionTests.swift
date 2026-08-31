import HexCore

@testable import HexIPC

extension HexGatewayClient {
  func installSequence(
    _ sequence: UInt64,
    runID: AgentRunID,
    invocationID: GatewayRunInvocationID
  ) {
    storeAcknowledgement(
      sequence,
      for: GatewayRunAcknowledgementKey(runID: runID, invocationID: invocationID)
    )
  }
}
