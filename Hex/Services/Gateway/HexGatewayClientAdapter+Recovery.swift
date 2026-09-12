import HexCore
import HexIPC

extension HexGatewayClientAdapter {
  func recoverRun(_ request: GatewayRunRecoveryRequest) async throws -> GatewayRunRecoveryResponse {
    try await client.recoverRun(request)
  }

  func readRunHistory(_ request: GatewayRunHistoryRequest) async throws -> GatewayRunHistoryPage {
    try await client.readRunHistory(request)
  }

  func eventRecords(
    for runID: AgentRunID, invocationID: GatewayRunInvocationID, afterSequence: UInt64
  ) async throws -> AsyncThrowingStream<GatewayEventEnvelope, any Error> {
    try await client.eventRecords(
      for: runID, invocationID: invocationID, afterSequence: afterSequence)
  }
}
