import HexCore
import HexIPC

struct OversizedFailureGatewayRunDriver: HexGatewayRunDriver {
  func run(
    _ request: GatewayStartRunRequest,
    emit: @escaping @Sendable (AgentEventRecord) async throws -> Void
  ) async throws {
    throw GatewayFailure(
      code: .runDriverFailed,
      message: String(repeating: "oversized-driver-failure", count: 512),
      isRetryable: true
    )
  }
}
