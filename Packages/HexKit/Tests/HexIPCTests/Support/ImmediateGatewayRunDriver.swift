import HexCore
import HexIPC

struct ImmediateGatewayRunDriver: HexGatewayRunDriver {
  func run(
    _ request: GatewayStartRunRequest,
    emit: @escaping @Sendable (AgentEventRecord) async throws -> Void
  ) async throws {
    try await emit(
      GatewayTestValues.record(runID: request.runID, sequence: 1, event: .runStarted)
    )
    try await emit(
      GatewayTestValues.record(runID: request.runID, sequence: 2, event: .runCompleted)
    )
  }
}
