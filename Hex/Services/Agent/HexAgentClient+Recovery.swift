import HexCore
import HexIPC

extension HexAgentClient {
  func recoverRun(_ request: GatewayRunRecoveryRequest) async throws -> GatewayRunRecoveryResponse {
    throw GatewayFailure(
      code: .transportUnavailable, message: "This connection cannot recover saved runs.")
  }

  func readRunHistory(_ request: GatewayRunHistoryRequest) async throws -> GatewayRunHistoryPage {
    throw GatewayFailure(
      code: .transportUnavailable, message: "This connection cannot read saved run history.")
  }

  func eventRecords(
    for runID: AgentRunID, invocationID: GatewayRunInvocationID, afterSequence: UInt64
  ) async throws -> AsyncThrowingStream<GatewayEventEnvelope, any Error> {
    throw GatewayFailure(
      code: .transportUnavailable, message: "This connection cannot restore an event cursor.")
  }
}
